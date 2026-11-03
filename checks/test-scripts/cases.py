# Each function's name says whether test-scripts.py finds it, and why. It reads only this file's text.
import json

with subtest("a helper is defined in one subtest"):
    forged = ["X-Forwarded-For"]

    def finds_a_list_a_later_subtest_assigns_again(host):
        return [f"-H '{name}: 192.0.2.1'" for name in forged]

    def passes_its_own_parameters_and_locals(forged, host):
        ns = host
        return forged, ns, [ns for ns in host]

    def passes_what_an_enclosing_function_binds(ns):
        tenant = ns

        def inner():
            return ns, tenant

        return inner

    def passes_a_default_taken_where_it_is_made(headers=forged):
        return headers

    def passes_a_name_bound_once_before_it():
        return json.dumps

    def passes_a_name_bound_once_after_it():
        return later_helper()

    def passes_a_name_only_comprehensions_bind():
        return comprehension_only

    def finds_a_name_bound_twice_after_it():
        return twice

    def finds_a_name_a_later_loop_binds():
        return looped

    def finds_what_its_inner_function_reads():
        def inner():
            return forged

        return inner

    finds_a_stored_lambda = lambda: forged

    finds_a_kept_generator = (forged for _ in range(2))

    def finds_a_lambda_default_reads(check=lambda: forged):
        return check

    finds_a_lambda_the_value_of_a_call_may_hold = polling_condition(lambda: forged)

    class Probe:
        def finds_in_a_method(self):
            return forged

    def finds_a_name_another_function_declares_global():
        return counter

    def finds_a_function_that_binds_a_global():
        global counter
        counter = 1

    def finds_a_name_another_function_imports_as_global():
        return shlex

    def finds_a_function_that_imports_a_global():
        global shlex
        import shlex

    def finds_a_driver_name_the_script_binds_once():
        log.info("x")

    def finds_a_machine_the_script_binds_once():
        return server.succeed("true")

    def finds_the_only_machine_by_the_name_machine():
        return machine.succeed("true")

    def finds_a_builtin_the_script_binds_once():
        return input()

    hooks = []

    def register(hook):
        hooks.append(hook)

    def copy(obj, change):
        change(obj)
        return obj

    # Kept by what they are handed to, though the statement may bind nothing.
    finds_a_generator_a_lazy_call_may_keep = map(str, (forged for _ in range(2)))
    finds_a_lambda_the_call_it_is_handed_on_to_may_keep = wrap(polling_condition(lambda: forged))
    finds_the_default_max_returns_when_empty = max([], default=lambda: forged)
    finds_a_generator_handed_to_a_name_the_script_binds = min(forged[0] for _ in range(2))
    hooks.append(lambda: forged)
    register(lambda: forged)

    # Done with where they are made, before the next subtest binds forged again.
    retry(lambda _: forged, timeout_seconds=1)
    assert any(name in forged for name in ["X-Real-IP"])
    first, second = (forged[0] for _ in range(2))
    passes_a_lambda_called_where_it_is_made = (lambda: forged)()
    passes_what_a_generator_was_consumed_into = sorted(name + forged[0] for name in ["a"])
    passes_what_a_string_joined = "".join(forged[0] for _ in range(2))
    passes_what_a_key_sorted = sorted(["a"], key=lambda name: name + forged[0])
    passes_what_a_call_returns_once_done_with_a_lambda = denied_by(copy(forged, lambda r: r.update(forged)))
    [comprehension_only for comprehension_only in forged]


with subtest("a later subtest"):
    forged = ["11111111-2222-3333-4444-555555555555 line"]
    twice = 1
    twice = 2
    for looped in [1, 2]:
        pass
    [comprehension_only for comprehension_only in forged]

    def later_helper():
        return 1

    log = "a log the subtest read"
    server = None
    machine = None
    input = "a name the subtest took"
    min = None

    marker = "/a"
    # Held while the body runs.
    with polling_condition(lambda: marker):
        marker = "/b"
    for line in map(lambda n: n + marker, ["x"]):
        marker = "/c"

for tenant in ["a", "b"]:

    def finds_a_loop_variable_from_inside_the_loop():
        return tenant
