import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

/**
 * Nothing tracked in this repository may name a retired deployment or a wallet that was never
 * part of it. A scratch script once did - swept into a commit by `git add -A`, carrying the
 * deprecated Base Sepolia splitter and a buyer address that must not be used - and a script that
 * hardcodes the wrong contract is one careless run from a real transaction against it.
 */
const FORBIDDEN = [
  // The first Base Sepolia P2FluxSponsoredSplitter: wrong economics, DEPRECATED_TEST_DEPLOYMENT.
  '0xe5dd4bdfbfdf1b8e40c7b6abffcb6712b12d02b3',
  // A wallet that was mistaken for the live-validation buyer and must not be used.
  '0x04b74ccd0fe75521a8039f74ca6a062ddb73eff0',
]

const tracked = execFileSync('git', ['ls-files', '-z'], { cwd: new URL('..', import.meta.url) })
  .toString('utf8')
  .split('\0')
  .filter((f) => f && !f.endsWith('.png') && !f.endsWith('.lock'))

test('no tracked file names a deprecated deployment or a forbidden wallet', () => {
  const offenders: string[] = []
  for (const file of tracked) {
    const text = readFileSync(new URL(`../${file}`, import.meta.url), 'utf8').toLowerCase()
    for (const needle of FORBIDDEN) if (text.includes(needle) && file !== 'test/hygiene.test.ts') offenders.push(`${file}: ${needle}`)
  }
  assert.deepEqual(offenders, [])
})

test('no scratch script is tracked', () => {
  // Anything under scripts/ that starts with an underscore is a session leftover, not a tool.
  assert.deepEqual(tracked.filter((f) => /^scripts\/_/.test(f)), [])
})
