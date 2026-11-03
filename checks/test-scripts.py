# Finds the functions in a NixOS test script that use a global the script binds again once they exist. The driver runs
# the whole script in one namespace, so such a function sees whatever a later subtest last left under that name.
import argparse
import ast
import builtins
import collections
import re
import symtable
import sys

COMPREHENSIONS = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
LOOPS = (ast.For, ast.While, *COMPREHENSIONS)
SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef, *COMPREHENSIONS)
# Python's functions that use up an iterable they are handed first, and those of them that take a key.
CONSUMERS = {"sorted", "sum", "any", "all", "min", "max", "list", "tuple", "set", "frozenset", "dict"}
KEYED = {"sorted", "min", "max"}


def module_code(tree):
    """Yields each node that runs in the module's own scope or a class body in it, with that scope's kind and whether
    the node is inside a comprehension, whose targets are its own."""

    def visit(node, scope, comp):
        yield node, scope, comp
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            # Defaults, decorators and annotations run where the function is made, its body when it is called.
            args = node.args
            outer = [*args.defaults, *args.kw_defaults]
            if not isinstance(node, ast.Lambda):
                params = [*args.posonlyargs, *args.args, *args.kwonlyargs, args.vararg, args.kwarg]
                outer += [*node.decorator_list, node.returns, *[a.annotation for a in params if a]]
            for child in outer:
                if child:
                    yield from visit(child, scope, comp)
        elif isinstance(node, ast.ClassDef):
            for child in [*node.decorator_list, *node.bases, *[k.value for k in node.keywords]]:
                yield from visit(child, scope, comp)
            for child in node.body:
                yield from visit(child, "class", False)
        elif isinstance(node, COMPREHENSIONS):
            first, *rest = node.generators
            yield from visit(first.iter, scope, comp)
            inner = [first.target, *first.ifs]
            for g in rest:
                inner += [g.target, g.iter, *g.ifs]
            inner += [node.key, node.value] if isinstance(node, ast.DictComp) else [node.elt]
            for child in inner:
                yield from visit(child, scope, True)
        elif isinstance(node, ast.NamedExpr):
            yield from visit(node.value, scope, comp)
        elif isinstance(node, ast.TypeAlias):
            yield from visit(node.name, scope, comp)
        else:
            for child in ast.iter_child_nodes(node):
                yield from visit(child, scope, comp)

    for stmt in tree.body:
        yield from visit(stmt, "module", False)


def bound_names(node, comp):
    """The names a node binds in the scope it runs in, each with the line it is bound on."""
    if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)) and not comp:
        return [(node.id, node.lineno)]
    if isinstance(node, ast.NamedExpr):
        return [(node.target.id, node.lineno)]
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        return [(node.name, node.end_lineno)]
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        if any(a.name == "*" for a in node.names):
            sys.exit(f"line {node.lineno}: a star import hides which names it binds")
        return [((a.asname or a.name).split(".")[0], node.lineno) for a in node.names]
    if isinstance(node, (ast.ExceptHandler, ast.MatchAs, ast.MatchStar)) and node.name:
        return [(node.name, node.lineno)]
    if isinstance(node, ast.MatchMapping) and node.rest:
        return [(node.rest, node.lineno)]
    return []


def module_bindings(tree):
    return [
        (name, line)
        for node, scope, comp in module_code(tree)
        if scope == "module"
        for name, line in bound_names(node, comp)
    ]


def only_calls(function, parameter, parents):
    """Whether a function does nothing with a parameter but call it, so that it holds what it was handed only until it
    returns: it neither keeps nor passes it on, nor uses it in a scope of its own, nor is a generator, whose frame
    outlives the call."""
    if parameter is None:
        return False
    for node in ast.walk(function):
        if isinstance(node, (ast.Yield, ast.YieldFrom)):
            return False
        if isinstance(node, ast.Name) and node.id == parameter:
            call = parents[node]
            if not (isinstance(node.ctx, ast.Load) and isinstance(call, ast.Call) and call.func is node):
                return False
            scope = call
            while scope is not function:
                if isinstance(scope, SCOPES):
                    return False
                scope = parents[scope]
    return True


def parameter_of(function, call, node, keyword):
    """The parameter of a function that the call hands node to."""
    args = function.args
    if keyword:
        return keyword.arg if keyword.arg in [a.arg for a in args.args + args.kwonlyargs] else None
    i = next(i for i, a in enumerate(call.args) if a is node)
    positional = args.posonlyargs + args.args
    if any(isinstance(a, ast.Starred) for a in call.args[:i]) or i >= len(positional):
        return None
    return positional[i].arg


def used_in_place(node, parents, unbound, functions):
    """Whether the statement that makes a lambda or generator expression is done with it: it calls it, unpacks it, or
    hands it to a call that is done with it once it returns. That is a function of Python's that uses up an iterable
    or calls a key, the driver's retry, or a function the script defines once that only calls that parameter, each
    under a name the script doesn't bind. Any other call may keep it, as polling_condition and map do."""
    parent = parents[node]
    keyword = parent if isinstance(parent, ast.keyword) else None
    call = parents[parent] if keyword else parent
    if not isinstance(call, ast.Call):
        return (
            isinstance(node, ast.GeneratorExp)
            and isinstance(parent, ast.Assign)
            and all(isinstance(t, (ast.Tuple, ast.List)) for t in parent.targets)
        )
    if call.func is node:
        return True
    name = call.func.id if isinstance(call.func, ast.Name) else None
    first = not keyword and call.args[0] is node
    if isinstance(node, ast.GeneratorExp):
        joins = isinstance(call.func, ast.Attribute) and call.func.attr == "join"
        return first and (
            joins
            and isinstance(call.func.value, ast.Constant)
            and isinstance(call.func.value.value, str)
            or name in CONSUMERS & unbound
        )
    if name in KEYED & unbound:
        return keyword is not None and keyword.arg == "key"
    if name == "retry" and name in unbound:
        return first or keyword is not None and keyword.arg == "fn"
    function = functions.get(name)
    return function is not None and only_calls(function, parameter_of(function, call, node, keyword), parents)


def tables(table):
    yield table
    for child in table.get_children():
        yield from tables(child)


def scan(source, prelude):
    tree = ast.parse(source)
    bindings = {name: [0] for name in prelude}
    for name, line in module_bindings(tree):
        bindings.setdefault(name, []).append(line)
    loops = [(node.lineno, node.end_lineno) for node, _, _ in module_code(tree) if isinstance(node, LOOPS)]

    def loop(line):
        """The outermost loop the module runs a line in, if any."""
        return min(((a, b) for a, b in loops if a <= line <= b), key=lambda r: (r[0], -r[1]), default=None)

    module = symtable.symtable(source, "script", "exec")
    # A function that declares a name global can bind it whenever it runs.
    anytime = {
        s.get_name()
        for t in tables(module)
        if t.get_type() != "module"
        for s in t.get_symbols()
        if s.is_declared_global() and (s.is_assigned() or s.is_imported())
    }
    # What the script binds where it runs, a class body's names among them, as a call there may mean one of those.
    bound_where_run = [(node, name) for node, _, comp in module_code(tree) for name, _ in bound_names(node, comp)]
    counts = collections.Counter(name for _, name in bound_where_run)
    unbound = {name for name in prelude if not counts[name] and name not in anytime}
    functions = {
        name: node
        for node, name in bound_where_run
        if isinstance(node, ast.FunctionDef)
        and not node.decorator_list
        and counts[name] == 1
        and name not in prelude
        and name not in anytime
    }

    parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
    in_place = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.Lambda, ast.GeneratorExp)):
            key = ("lambda" if isinstance(node, ast.Lambda) else "genexpr", node.lineno)
            in_place[key] = in_place.get(key, True) and used_in_place(node, parents, unbound, functions)

    def deferred(table):
        """The scopes made where the module runs, whose code runs later: a class body runs where it stands, and so does
        a lambda or generator expression used in place."""
        for child in table.get_children():
            if child.get_type() == "class" or in_place.get((child.get_name(), child.get_lineno()), False):
                yield from deferred(child)
            else:
                yield child

    lines = source.splitlines()
    findings = []
    for root in deferred(module):
        start = root.get_lineno()
        # A global statement makes even an augmented assignment use the global, which symtable counts as no read.
        uses = {
            s.get_name()
            for t in tables(root)
            for s in t.get_symbols()
            if s.is_global() and (s.is_referenced() or s.is_declared_global())
        }
        for name in sorted(uses):
            bound = bindings.get(name, [])
            later = [line for line in bound if line >= start or (loop(start) and loop(line) == loop(start))]
            if name in anytime or (later and (len(bound) > 1 or any(loop(line) for line in later))):
                where = f"again at {', '.join(map(str, later))}" if later else "in a function that declares it global"
                findings.append(
                    f"{start}: {root.get_name()} uses the global {name}, which the script binds {where}:"
                    f" {lines[start - 1].strip()}"
                )
    return findings


def driver_names(path):
    """The names the driver binds for every script: what test_symbols() makes its general_symbols of."""
    with open(path) as f:
        tree = ast.parse(f.read())
    methods = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "test_symbols"]
    body = methods[0].body if len(methods) == 1 else []
    made = [n.value for n in body if isinstance(n, ast.Assign) and ast.unparse(n).startswith("general_symbols = ")]
    returned = [ast.unparse(n.value) for n in body if isinstance(n, ast.Return)]
    # Fails rather than miss a name should the driver come to bind its symbols another way.
    if (
        len(made) != 1
        or not (isinstance(made[0], ast.Call) and ast.unparse(made[0].func) == "dict" and not made[0].args)
        or not all(k.arg for k in made[0].keywords)
        or returned != ["{**general_symbols, **machine_symbols, **vlan_symbols}"]
    ):
        sys.exit(f"{path}: test_symbols() no longer binds the names as test-scripts.py reads them")
    return {k.arg for k in made[0].keywords}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--driver", required=True, help="the test driver's driver.py, which binds names for the script")
    parser.add_argument("--machine", action="append", default=[])
    parser.add_argument("--vlan", action="append", default=[])
    parser.add_argument("label")
    parser.add_argument("script")
    args = parser.parse_args()
    # As the driver names machines and VLANs, and an only machine of another name as machine too. A builtin is bound
    # before the script as well, so the script's first binding of one already changes what an earlier function gets.
    machines = {re.sub(r"^[^A-Za-z_]|[^A-Za-z0-9_]", "_", name) for name in args.machine}
    if len(args.machine) == 1 and "machine" not in machines:
        machines.add("machine")
    prelude = driver_names(args.driver) | machines | {f"vlan{n}" for n in args.vlan} | set(dir(builtins))
    with open(args.script) as f:
        findings = scan(f.read(), prelude)
    for finding in findings:
        print(f"{args.label}:{finding}")
    if not findings:
        print(f"ok {args.label}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
