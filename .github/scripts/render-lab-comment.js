// Renders the sticky lab-environment PR comment. Called from
// .github/workflows/lab-provision.yml via actions/github-script.
//
// Environment inputs (populated by the workflow):
//   STATUS, LAB, SCENARIO, TTL, TTL_ISO, NOTES,
//   INSTANCE_ID, VPC_ID, REGION,
//   PROBE_LOG_GROUP, FLOW_LOG_GROUP,
//   PROBE_JSON, RUN_URL

const COMMENT_HEADER = '<!-- lab-environment:v1 -->';

function envOr(name, fallback = '') {
  const v = process.env[name];
  return v === undefined || v === null || v === '' ? fallback : v;
}

function statusBadge(status) {
  switch (status) {
    case 'ready':
      return '`ready`';
    case 'probe-failed':
      return '`probe-failed`';
    case 'provision-failed':
      return '`provision-failed`';
    default:
      return `\`${status}\``;
  }
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

function probeListMatrix(rows, matchedExpectation) {
  const summary = matchedExpectation
    ? 'all checks matched expectations'
    : 'one or more checks did NOT match expectations';
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

function probeGridMatrix(rows, matchedExpectation) {
  const cells = new Map();
  const tiers = [];
  const seenTier = new Set();
  for (const r of rows) {
    if (!r.source || !r.destination || r.source === 'probe') continue;
    for (const t of [r.source, r.destination]) {
      if (!seenTier.has(t)) {
        seenTier.add(t);
        tiers.push(t);
      }
    }
    cells.set(`${r.source}->${r.destination}`, r);
  }
  if (tiers.length === 0) return null;

  const tierOrder = ['web', 'app', 'db'].filter((t) => seenTier.has(t));
  for (const t of tiers) {
    if (!tierOrder.includes(t)) tierOrder.push(t);
  }

  const headerCells = ['source ↓ \\ dest →', ...tierOrder.map((t) => `\`${t}\``)];
  const sepCells = headerCells.map(() => '---');
  const lines = [headerCells.join(' | '), sepCells.join(' | ')];
  for (const src of tierOrder) {
    const row = [`\`${src}\``];
    for (const dst of tierOrder) {
      if (src === dst) {
        row.push('—');
        continue;
      }
      const cell = cells.get(`${src}->${dst}`);
      if (!cell) {
        row.push('·');
        continue;
      }
      const port = cell.port ? `:${cell.port}` : '';
      const actual = cell.passed ? 'pass' : 'fail';
      const marker = cell.matched_expectation ? '' : ' *';
      row.push(`${actual}${port}${marker}`);
    }
    lines.push(row.join(' | '));
  }

  const details = rows
    .filter((r) => r.source && r.source !== 'probe')
    .map((r) => {
      const expected = r.expected ? 'pass' : 'fail';
      const actual = r.passed ? 'pass' : 'fail';
      const marker = r.matched_expectation ? '' : ' *';
      const detail = String(r.detail || '').replace(/\|/g, '\\|');
      return `| \`${r.name}\`${marker} | ${expected} | ${actual} | ${detail} | ${r.duration_ms} |`;
    });
  const detailTable = details.length
    ? `\n\n<details><summary>per-path detail</summary>\n\n| path | expected | actual | detail | ms |\n|---|---|---|---|---|\n${details.join('\n')}\n\n</details>`
    : '';

  const summary = matchedExpectation
    ? 'all paths matched expectations'
    : 'one or more paths did NOT match expectations (marked `*`)';
  return `${lines.join('\n')}\n\n_${summary}_${detailTable}`;
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
  const isGrid =
    parsed.lab === 'three-tier-segmentation' ||
    rows.some((r) => r && r.source && r.source !== 'probe' && r.destination);
  if (isGrid) {
    const grid = probeGridMatrix(rows, parsed.matched_expectation);
    if (grid) return grid;
  }
  return probeListMatrix(rows, parsed.matched_expectation);
}

module.exports = async ({github, context}) => {
  const status = envOr('STATUS', 'unknown');
  const lab = envOr('LAB');
  const scenario = envOr('SCENARIO');
  const ttl = envOr('TTL');
  const ttlIso = envOr('TTL_ISO');
  const notes = envOr('NOTES');
  const instanceId = envOr('INSTANCE_ID');
  const instanceIdsJson = envOr('INSTANCE_IDS_JSON');
  const vpcId = envOr('VPC_ID');
  const region = envOr('REGION');

  let tierInstances = null;
  if (instanceIdsJson) {
    try {
      const parsed = JSON.parse(instanceIdsJson);
      if (parsed && typeof parsed === 'object' && Object.keys(parsed).length > 0) {
        tierInstances = parsed;
      }
    } catch (err) {
      // fall through; tierInstances stays null
    }
  }
  const probeLogGroup = envOr('PROBE_LOG_GROUP');
  const flowLogGroup = envOr('FLOW_LOG_GROUP');
  const probeJson = envOr('PROBE_JSON');
  const runUrl = envOr('RUN_URL');

  const isTeardown = status === 'destroyed' || status === 'destroy-failed';

  const sessionCommands = tierInstances
    ? Object.entries(tierInstances)
        .map(([tier, id]) => `# ${tier}\naws ssm start-session --region ${region} --target ${id}`)
        .join('\n')
    : instanceId
      ? `aws ssm start-session --region ${region} --target ${instanceId}`
      : null;
  const startSession = sessionCommands
    ? `\`\`\`bash\n${sessionCommands}\n\`\`\``
    : '_instance not provisioned_';

  const logGroupLink = (name) => {
    if (!name) return '—';
    const encoded = encodeURIComponent(encodeURIComponent(name));
    return `[\`${name}\`](https://${region}.console.aws.amazon.com/cloudwatch/home?region=${region}#logsV2:log-groups/log-group/${encoded})`;
  };

  const teardownBody = [
    COMMENT_HEADER,
    '### lab environment',
    '',
    `**status:** ${statusBadge(status)}`,
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
    `**status:** ${statusBadge(status)}`,
    '',
    `| | |`,
    `|---|---|`,
    `| lab | \`${lab}\` |`,
    `| scenario | \`${scenario}\` |`,
    `| ttl | \`${ttl}\` — ${ttlCountdown(ttlIso)} |`,
    `| region | \`${region}\` |`,
    `| vpc | \`${vpcId || '—'}\` |`,
    tierInstances
      ? `| instances | ${Object.entries(tierInstances).map(([t, i]) => `\`${t}=${i}\``).join(', ')} |`
      : `| instance | \`${instanceId || '—'}\` |`,
    notes ? `| notes | ${notes} |` : null,
    '',
    '#### SSM session',
    startSession,
    '',
    '#### probe matrix',
    probeMatrix(probeJson),
    '',
    '#### logs',
    `- probe: ${logGroupLink(probeLogGroup)}`,
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
