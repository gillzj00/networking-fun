// Renders the sticky lab-environment PR comment. Called from
// .github/workflows/lab-provision.yml and lab-destroy.yml via
// actions/github-script.
//
// Environment inputs (populated by the workflow):
//   STATUS, LAB, SCENARIO, TTL, TTL_ISO, NOTES,
//   ENDPOINT, CLUSTER, SERVICE, VPC_ID, REGION,
//   CONTAINER_LOG_GROUP, FLOW_LOG_GROUP,
//   PROBE_JSON, RUN_URL

const COMMENT_HEADER = '<!-- lab-environment:v1 -->';

function envOr(name, fallback = '') {
  const v = process.env[name];
  return v === undefined || v === null || v === '' ? fallback : v;
}

function ttlCountdown(ttlIso) {
  if (!ttlIso) return '—';
  const expires = Date.parse(ttlIso);
  if (Number.isNaN(expires)) return ttlIso;
  const ms = expires - Date.now();
  if (ms <= 0) return `expired at ${ttlIso}`;
  const totalMin = Math.floor(ms / 60_000);
  const hours = Math.floor(totalMin / 60);
  const mins = totalMin % 60;
  const parts = [];
  if (hours) parts.push(`${hours}h`);
  parts.push(`${mins}m`);
  return `~${parts.join(' ')} remaining (expires ${ttlIso})`;
}

function probeMatrix(probeJsonRaw) {
  if (!probeJsonRaw) {
    return '_probe was not invoked_';
  }
  let parsed;
  try {
    parsed = JSON.parse(probeJsonRaw);
  } catch (err) {
    return `_probe output not parseable: ${err.message}_\n\n\`\`\`\n${probeJsonRaw}\n\`\`\``;
  }
  const rows = parsed.results || [];
  if (rows.length === 0) {
    return '_probe returned no checks_';
  }
  const summary = parsed.matched_expectation
    ? 'all checks matched expectations'
    : 'one or more checks did NOT match expectations (marked `*`)';
  const header = '| check | expected | actual | detail | ms |\n|---|---|---|---|---|';
  const lines = rows.map((r) => {
    const expected = r.expected ? 'pass' : 'fail';
    const actual = r.passed ? 'pass' : 'fail';
    const marker = r.matched_expectation ? '' : ' *';
    const detail = String(r.detail || '').replace(/\|/g, '\\|');
    return `| \`${r.name}\`${marker} | ${expected} | ${actual} | ${detail} | ${r.duration_ms} |`;
  });
  return `${header}\n${lines.join('\n')}\n\n_${summary}_`;
}

module.exports = async ({github, context}) => {
  const status = envOr('STATUS', 'unknown');
  const lab = envOr('LAB');
  const scenario = envOr('SCENARIO');
  const ttl = envOr('TTL');
  const ttlIso = envOr('TTL_ISO');
  const notes = envOr('NOTES');
  const endpoint = envOr('ENDPOINT');
  const cluster = envOr('CLUSTER');
  const service = envOr('SERVICE');
  const vpcId = envOr('VPC_ID');
  const region = envOr('REGION');
  const containerLogGroup = envOr('CONTAINER_LOG_GROUP');
  const flowLogGroup = envOr('FLOW_LOG_GROUP');
  const probeJson = envOr('PROBE_JSON');
  const runUrl = envOr('RUN_URL');

  const isTeardown = status === 'destroyed' || status === 'destroy-failed';

  const endpointSection = endpoint
    ? [
        `[${endpoint}](${endpoint}) — try it from your own machine:`,
        '',
        '```bash',
        `curl ${endpoint}/`,
        `curl ${endpoint}/healthz`,
        '```',
      ].join('\n')
    : '_no reachable endpoint — see the probe matrix for why_';

  const logGroupLink = (name) => {
    if (!name) return '—';
    const encoded = encodeURIComponent(encodeURIComponent(name));
    return `[\`${name}\`](https://${region}.console.aws.amazon.com/cloudwatch/home?region=${region}#logsV2:log-groups/log-group/${encoded})`;
  };

  const teardownBody = [
    COMMENT_HEADER,
    '### lab environment',
    '',
    `**status:** \`${status}\``,
    '',
    status === 'destroyed'
      ? 'All lab resources for this PR have been destroyed.'
      : 'Destroy did not complete cleanly — check the workflow run and the janitor Lambda will sweep anything still tagged with an expired `AutoDelete`.',
    '',
    `_Workflow run: [${context.runId}](${runUrl})_`,
  ].join('\n');

  const provisionBody = [
    COMMENT_HEADER,
    '### lab environment',
    '',
    `**status:** \`${status}\``,
    '',
    `| | |`,
    `|---|---|`,
    `| lab | \`${lab}\` |`,
    `| scenario | \`${scenario}\` |`,
    `| ttl | \`${ttl}\` — ${ttlCountdown(ttlIso)} |`,
    `| region | \`${region}\` |`,
    `| cluster / service | \`${cluster || '—'}\` / \`${service || '—'}\` |`,
    `| vpc | \`${vpcId || '—'}\` |`,
    notes ? `| notes | ${notes} |` : null,
    '',
    '#### endpoint',
    endpointSection,
    '',
    '#### probe matrix',
    probeMatrix(probeJson),
    '',
    '#### logs',
    `- container: ${logGroupLink(containerLogGroup)}`,
    `- VPC flow logs: ${logGroupLink(flowLogGroup)}`,
    '',
    `_Comment \`/lab destroy\` to force teardown. Workflow run: [${context.runId}](${runUrl})_`,
  ]
    .filter((line) => line !== null)
    .join('\n');

  const body = isTeardown ? teardownBody : provisionBody;

  const {owner, repo} = context.repo;
  const issue_number = context.payload.pull_request
    ? context.payload.pull_request.number
    : context.payload.issue.number;

  const existing = await github.paginate(github.rest.issues.listComments, {
    owner,
    repo,
    issue_number,
    per_page: 100,
  });
  const ours = existing.find(
    (c) => c.user && c.user.type === 'Bot' && c.body && c.body.includes(COMMENT_HEADER),
  );

  if (ours) {
    await github.rest.issues.updateComment({
      owner,
      repo,
      comment_id: ours.id,
      body,
    });
  } else {
    await github.rest.issues.createComment({
      owner,
      repo,
      issue_number,
      body,
    });
  }
};
