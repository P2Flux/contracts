/**
 * Copy the compiled ABIs into `abi/`, so consumers get them without running solc.
 *
 * `--check` compares instead of writing, and exits non-zero on drift. That is the guard that keeps
 * the committed artifacts honest: they are a BUILD OUTPUT of the .sol files in this same repo, not a
 * second editable copy, and the only way they can be trusted is if regenerating them is a no-op.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const root = new URL('..', import.meta.url).pathname
const PUBLISHED = ['P2FluxRecurring', 'P2FluxSplitter']
const check = process.argv.includes('--check')

if (!existsSync(join(root, 'out'))) {
  console.error('no out/ - run `npm run compile` first')
  process.exit(1)
}
mkdirSync(join(root, 'abi'), { recursive: true })

let drift = 0
for (const name of PUBLISHED) {
  const { abi } = JSON.parse(readFileSync(join(root, 'out', `${name}.json`), 'utf8')) as { abi: unknown }
  const target = join(root, 'abi', `${name}.json`)
  const next = `${JSON.stringify(abi, null, 2)}\n`
  if (check) {
    const current = existsSync(target) ? readFileSync(target, 'utf8') : ''
    if (current !== next) {
      console.error(`DRIFT: abi/${name}.json does not match a fresh compile`)
      drift++
    }
    continue
  }
  writeFileSync(target, next)
  console.log(`wrote abi/${name}.json`)
}
if (drift) process.exit(1)
if (check) console.log('abi/ matches a fresh compile')
