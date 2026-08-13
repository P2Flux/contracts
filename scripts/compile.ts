import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'

const require = createRequire(import.meta.url)
const solc = require('solc')

const root = new URL('..', import.meta.url).pathname
const CONTRACTS = ['P2FluxSplitter.sol', 'P2FluxRecurring.sol', 'test/MockTokens.sol']

const sources: Record<string, { content: string }> = {}
for (const name of CONTRACTS) {
  sources[name] = { content: readFileSync(join(root, 'contracts', name), 'utf8') }
}

/** Resolve @openzeppelin/... imports from node_modules; anything else relative to contracts/. */
function findImport(path: string): { contents: string } | { error: string } {
  for (const candidate of [join(root, 'node_modules', path), join(root, 'contracts', path)]) {
    if (existsSync(candidate)) return { contents: readFileSync(candidate, 'utf8') }
  }
  return { error: `import not found: ${path}` }
}

const output = JSON.parse(
  solc.compile(
    JSON.stringify({
      language: 'Solidity',
      sources,
      settings: {
        optimizer: { enabled: true, runs: 200 },
        evmVersion: 'cancun',
        outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
      },
    }),
    { import: findImport },
  ),
)

let failed = false
for (const err of output.errors ?? []) {
  if (err.severity === 'error') {
    console.error(err.formattedMessage)
    failed = true
  }
}
if (failed) process.exit(1)

mkdirSync(join(root, 'out'), { recursive: true })
for (const file of CONTRACTS) {
  for (const [name, contract] of Object.entries(output.contracts[file] ?? {}) as [string, any][]) {
    if (!contract.evm?.bytecode?.object) continue
    writeFileSync(
      join(root, 'out', `${name}.json`),
      JSON.stringify({ abi: contract.abi, bytecode: `0x${contract.evm.bytecode.object}` }, null, 2),
    )
    console.log(`${name}: ${contract.evm.bytecode.object.length / 2} bytes -> out/${name}.json`)
  }
}
console.log(`solc ${solc.version()}`)
