import { readFileSync } from 'node:fs'

/**
 * Aderyn's counterpart to slither.db.json: every finding in a deployed contract was reviewed
 * (docs/security-analysis.md), and aderyn.reviewed.json holds how many of each detector each file
 * may have. More than that - a new detector, or a new instance in a reviewed one - fails the build.
 * Test mocks (contracts/test/) are never deployed and are not counted.
 *
 *   aderyn . -o aderyn-report.json && tsx scripts/aderyn-check.ts aderyn-report.json
 */
type Issue = { detector_name: string; instances: { contract_path: string }[] }
const report = JSON.parse(readFileSync(process.argv[2] ?? 'aderyn-report.json', 'utf8')) as Record<'high_issues' | 'low_issues', { issues: Issue[] }>
const write = process.argv.includes('--write')
// --write prints a new baseline (redirected over the file), so it must not read the old one.
const reviewed = write ? {} : (JSON.parse(readFileSync(new URL('../aderyn.reviewed.json', import.meta.url), 'utf8')) as Record<string, number>)

const found: Record<string, number> = {}
for (const issue of [...report.high_issues.issues, ...report.low_issues.issues])
  for (const { contract_path } of issue.instances)
    if (!contract_path.startsWith('contracts/test/')) found[`${issue.detector_name} ${contract_path}`] = (found[`${issue.detector_name} ${contract_path}`] ?? 0) + 1

const fresh = Object.entries(found).filter(([key, n]) => n > (reviewed[key] ?? 0))
if (write) console.log(JSON.stringify(Object.fromEntries(Object.entries(found).sort()), null, 2))
else if (fresh.length) {
  for (const [key, n] of fresh) console.error(`new Aderyn finding: ${key} (${n}, reviewed ${reviewed[key] ?? 0})`)
  process.exit(1)
} else console.log(`aderyn: ${Object.values(found).reduce((a, b) => a + b, 0)} findings, all reviewed`)
