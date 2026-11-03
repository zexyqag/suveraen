-- What suveraen-mesh check reads of a tenant's mesh (mesh.sh), as one JSON object: who is in it, what each may reach
-- and how, and what reaches beyond it; of its peers no name, address or inventory, and of what they route to only the
-- kind of address and a digest that changes with it; and whether the scrub keeps devices' inventory out: its trigger,
-- the columns of peers it doesn't know (psql's variables scrubbed and kept), and the peers it would change. NetBird keeps
-- lists and resources as JSON text, and addresses as quoted JSON strings.
with
  resources as (
    select network_id, id, type, enabled, nullif(trim(both '"' from prefix), '')::inet as prefix,
      md5(concat(prefix, ' ', domain)) as digest
    from network_resources
  ),
  private(range) as (values ('10.0.0.0/8'::inet), ('172.16.0.0/12'), ('192.168.0.0/16'))
select json_build_object(
  'users', (select coalesce(json_agg(json_build_object('id', id, 'role', role, 'blocked', blocked,
      'pending', pending_approval, 'service', is_service_user, 'autoGroups', nullif(auto_groups, '')::jsonb) order by id),
    '[]') from users),
  'pats', (select coalesce(json_agg(json_build_object('id', id, 'user', user_id) order by id), '[]')
    from personal_access_tokens),
  'setupKeys', (select coalesce(json_agg(json_build_object('id', id, 'type', type, 'revoked', revoked,
      'usageLimit', usage_limit, 'autoGroups', nullif(auto_groups, '')::jsonb,
      'validSeconds', extract(epoch from expires_at - created_at)) order by id), '[]') from setup_keys),
  'groups', (select coalesce(json_agg(json_build_object('id', g.id, 'name', g.name,
      'peers', (select coalesce(json_agg(p.peer_id order by p.peer_id), '[]') from group_peers p where p.group_id = g.id),
      'resources', nullif(g.resources, '')::jsonb) order by g.id), '[]') from groups g),
  'policies', (select coalesce(json_agg(json_build_object('id', p.id, 'enabled', p.enabled,
      'postureChecks', nullif(p.source_posture_checks, '')::jsonb,
      'rules', (select coalesce(json_agg(json_build_object('id', r.id, 'enabled', r.enabled, 'action', r.action,
          'sources', nullif(r.sources, '')::jsonb, 'destinations', nullif(r.destinations, '')::jsonb,
          'sourceResource', nullif(r.source_resource, '')::jsonb,
          'destinationResource', nullif(r.destination_resource, '')::jsonb, 'bidirectional', r.bidirectional,
          'protocol', r.protocol, 'ports', nullif(r.ports, '')::jsonb, 'portRanges', nullif(r.port_ranges, '')::jsonb,
          'authorizedGroups', nullif(r.authorized_groups, '')::jsonb, 'authorizedUser', r.authorized_user) order by r.id),
        '[]') from policy_rules r where r.policy_id = p.id)) order by p.id), '[]') from policies p),
  'routes', (select coalesce(json_agg(id order by id), '[]') from routes),
  'networks', (select coalesce(json_agg(json_build_object('id', n.id,
      'routers', (select coalesce(json_agg(json_build_object('id', x.id, 'peer', nullif(x.peer, ''),
          'peerGroups', nullif(x.peer_groups, '')::jsonb) order by x.id), '[]') from network_routers x
        where x.network_id = n.id),
      'resources', (select coalesce(json_agg(json_build_object('id', r.id, 'type', r.type, 'enabled', r.enabled,
          'digest', r.digest, 'family', family(r.prefix), 'maskLength', masklen(r.prefix),
          'private', family(r.prefix) = 4 and exists (select 1 from private v where r.prefix <<= v.range))
          order by r.id), '[]') from resources r where r.network_id = n.id)) order by n.id), '[]') from networks n),
  'postureChecks', (select coalesce(json_agg(json_build_object('id', id, 'checks', nullif(checks, '')::jsonb) order by id),
    '[]') from posture_checks),
  'peers', (select coalesce(json_agg(json_build_object('id', id, 'user', nullif(user_id, ''), 'version', meta_wt_version,
      'loginExpiry', login_expiration_enabled, 'embeddedProxy', proxy_meta_embedded) order by id), '[]') from peers),
  'settings', (select json_build_object('userApproval', settings_extra_user_approval_required,
      'jwtGroups', settings_jwt_groups_enabled, 'groupsPropagation', settings_groups_propagation_enabled,
      'metricsPush', settings_metrics_push_enabled, 'autoUpdate', settings_auto_update_version,
      'loginExpiry', settings_peer_login_expiration_enabled,
      'loginExpirySeconds', settings_peer_login_expiration / 1000000000, 'dnsDomain', settings_dns_domain,
      'peerExpose', settings_peer_expose_enabled, 'ipv6Groups', nullif(settings_ipv6_enabled_groups, '')::jsonb)
    from accounts),
  'counts', json_build_object(
    'nameserverGroups', (select count(*) from name_server_groups),
    'zones', (select count(*) from zones),
    'records', (select count(*) from records),
    'jobs', (select count(*) from jobs),
    'proxyTokens', (select count(*) from proxy_access_tokens),
    'services', (select count(*) from services),
    'targets', (select count(*) from targets),
    'domains', (select count(*) from domains),
    'proxies', (select count(*) from proxies),
    'accessLog', (select count(*) from access_log_entries),
    'invites', (select count(*) from user_invites),
    'agentNetwork', (select sum(n) from (
      select count(*) as n from agent_network_providers
      union all select count(*) from agent_network_policies
      union all select count(*) from agent_network_guardrails
      union all select count(*) from agent_network_budget_rules
      union all select count(*) from agent_network_settings
      union all select count(*) from agent_network_consumption
      union all select count(*) from agent_network_access_log
      union all select count(*) from agent_network_access_log_group
      union all select count(*) from agent_network_request_usage
      union all select count(*) from agent_network_request_usage_group) as agent)
  ),
  'scrub', json_build_object(
    'trigger', (select json_build_object('definition', pg_get_triggerdef(oid), 'enabled', tgenabled) from pg_trigger
      where tgrelid = 'peers'::regclass and tgname = 'scrub'),
    'gone', (select coalesce(json_agg(c order by c), '[]') from jsonb_object_keys(:'scrubbed'::jsonb) c
      where c not in (select attname from pg_attribute where attrelid = 'peers'::regclass and attnum > 0
        and not attisdropped)),
    'unreviewed', (select coalesce(json_agg(attname order by attname), '[]') from pg_attribute
      where attrelid = 'peers'::regclass and attnum > 0 and not attisdropped and attname like 'meta\_%'
        and not (:'scrubbed'::jsonb ? attname or :'kept'::jsonb ? attname)),
    'unscrubbed', (select coalesce(json_agg(id order by id), '[]') from peers p
      where to_jsonb(jsonb_populate_record(p, :'scrubbed'::jsonb)) <> to_jsonb(p)),
    -- Addresses with their MACs, in a table NetBird makes and nothing writes yet.
    'networkAddresses', (select count(*) from network_addresses))
);
