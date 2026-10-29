// Builds the API reference pages (docs/api/*.md) from the Luau sources, so the
// reference can never drift from the code. Runs before every docs build.
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
const SRC = join(ROOT, 'src', 'Corode')
const OUT = join(ROOT, 'docs', 'api')
const SIDEBAR = join(ROOT, 'docs', '.vitepress', 'api-sidebar.json')

// Modules exposed on K, with the file they live in. Internal helpers are left out.
const MODULES = [
  ['When', 'When'], ['Value', 'Value'], ['Action', 'Action'], ['Hooks', 'Hooks'], ['Tag', 'Tag'], ['Shared', 'Shared'], ['Timer', 'Timer'], ['Machine', 'Machine'], ['Currency', 'Currency'], ['Leaderstats', 'Leaderstats'], ['Data', 'Data'],
  ['Items', 'Items'], ['Inventory', 'Inventory'], ['Stats', 'Stats'], ['Combat', 'Combat'],
  ['NPC', 'NPC'], ['Quests', 'Quests'], ['Rewards', 'Rewards'], ['Rounds', 'Rounds'], ['Teams', 'Teams'], ['Shop', 'Shop'],
  ['Global', 'Global'], ['AntiCheat', 'AntiCheat'], ['Admin', 'Admin'], ['Analytics', 'Analytics'],
  ['UI', 'UI'], ['Input', 'Input'], ['Players', 'Players'], ['Net', 'Net'], ['Notify', 'Notify'],
  ['Badges', 'Badges'], ['Motion', 'Motion'], ['Timing', 'Timing'], ['Config', 'Config'],
  ['Guard', 'Util/Guard'], ['Format', 'Util/Format'], ['Signal', 'Util/Signal'], ['Trove', 'Util/Trove'],
]

// Tables whose functions are methods on objects a module hands out.
const METHOD_OWNERS = {
  Chain: 'chain', ActionMethods: 'action', ServerMethods: 'inventory', ClientMethods: 'inventory',
  NpcMethods: 'npc', Handle: 'handle', Signal: 'signal', Trove: 'trove', PacketMethods: 'packet',
}

// Method tables whose meaning depends on the module they're in.
const MODULE_METHOD_OWNERS = {
  Value: { ServerMethods: 'value', ClientMethods: null },
  Action: { ServerMethods: 'action', ClientMethods: 'action' },
  Hooks: { HookMethods: 'hooks' },
  Tag: { Behavior: 'behavior' },
  Shared: { Methods_: 'shared' },
  Timer: { TimerMethods: 'timer' },
  Machine: { ServerMethods: 'machine', ClientMethods: null },
}

const escapeText = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

function header(lines) {
  if (!lines[0]?.startsWith('--[[')) return null
  const end = lines.findIndex((line) => line.includes(']]'))
  const body = lines.slice(1, end).map((line) => line.replace(/^\t/, ''))
  // The first line repeats the module name; the summary runs until the first blank line.
  let summaryEnd = 1
  while (summaryEnd < body.length && body[summaryEnd].trim() !== '') summaryEnd += 1
  const summary = body.slice(1, summaryEnd).map((line) => line.trim()).join(' ')
  return { summary, details: body.slice(summaryEnd).join('\n').replace(/^\n+|\s+$/g, '') }
}

function commentAbove(lines, index) {
  const comment = []
  for (let i = index - 1; i >= 0 && /^--(?!\[\[)/.test(lines[i]); i--) {
    comment.unshift(lines[i].replace(/^--\s?/, ''))
  }
  return comment.join(' ')
}

function signatureAt(lines, index) {
  let text = lines[index]
  let depth = 0
  for (let i = index; ; ) {
    for (const char of lines[i]) depth += char === '(' ? 1 : char === ')' ? -1 : 0
    if (depth <= 0 || i + 1 >= lines.length) break
    i += 1
    text += ' ' + lines[i].trim()
  }
  return text.replace(/^function\s+/, '').trim()
}

function parse(name, file) {
  const lines = readFileSync(join(SRC, file + '.luau'), 'utf8').split('\n')
  // Table.Name(self, ...) is a method on the table's objects, not a module function.
  const isSelfMethod = (line) => /^function \w+\.\w+(<[^>]*>)?\(self\b/.test(line)
  const prefixCounts = {}
  for (const line of lines) {
    const match = /^function (\w+)\./.exec(line)
    if (match && !isSelfMethod(line)) prefixCounts[match[1]] = (prefixCounts[match[1]] ?? 0) + 1
  }
  const owners = { ...METHOD_OWNERS, ...(MODULE_METHOD_OWNERS[name] ?? {}) }
  const owner = Object.entries(prefixCounts).sort((a, b) => b[1] - a[1])
    .map(([prefix]) => prefix).find((prefix) => !(prefix in owners) || prefix === name) ?? name

  const functions = []
  const methods = {}
  const events = []
  lines.forEach((line, index) => {
    const fn = /^function (\w+)([.:])(\w+)/.exec(line)
    if (fn && !fn[3].startsWith('_')) {
      const [, table, separator, member] = fn
      const signature = signatureAt(lines, index)
      const comment = commentAbove(lines, index)
      if (separator === '.' && table === owner && !isSelfMethod(line)) {
        functions.push({ title: `K.${name}.${member}`, code: 'K.' + name + signature.slice(table.length), comment })
      } else if (owners[table]) {
        const label = owners[table]
        let params = signature.slice(table.length + 1 + member.length)
        // Methods written as Table.Name(object, ...) take the object as their first parameter.
        if (separator === '.') params = params.replace(/^(<[^>]*>)?\((\w+)(\s*:\s*\w+)?(,\s*)?/, '$1(')
        ;(methods[label] ??= []).push({ title: `${label}:${member}`, code: `${label}:${member}${params}`, comment })
      }
    }
    const signal = new RegExp(`^${owner}\\.(\\w+) = Signal\\.new\\(\\)`).exec(line)
    if (signal) events.push({ title: `K.${name}.${signal[1]}`, comment: commentAbove(lines, index) })
  })
  return { name, header: header(lines), functions, methods, events }
}

function entry({ title, code, comment }) {
  let text = `### ${title}\n\n`
  if (code) text += '```lua\n' + code + '\n```\n\n'
  if (comment) text += escapeText(comment) + '\n\n'
  return text
}

function page(module) {
  let text = `---\ntitle: K.${module.name}\noutline: [2, 3]\n---\n\n# K.${module.name}\n\n::: v-pre\n`
  if (module.header) {
    text += escapeText(module.header.summary) + '\n\n'
    if (module.header.details) text += '```lua\n' + module.header.details + '\n```\n\n'
  }
  if (module.functions.length) text += '## Functions\n\n' + module.functions.map(entry).join('')
  if (module.events.length) text += '## Events\n\n' + module.events.map(entry).join('')
  for (const [label, list] of Object.entries(module.methods)) {
    text += `## Methods on ${label}\n\n` + list.map(entry).join('')
  }
  text += ':::\n\n> Generated from `src/Corode/' + MODULES.find(([n]) => n === module.name)[1] + '.luau`.\n'
  return text
}

rmSync(OUT, { recursive: true, force: true })
mkdirSync(OUT, { recursive: true })
const modules = MODULES.map(([name, file]) => parse(name, file))
for (const module of modules) {
  writeFileSync(join(OUT, module.name.toLowerCase() + '.md'), page(module))
}
writeFileSync(join(OUT, 'index.md'),
  '# API reference\n\nEvery public function, event and method, generated from the source on each build.\n\n' +
  '| Module | What it does |\n| --- | --- |\n' +
  modules.map((m) => `| [K.${m.name}](./${m.name.toLowerCase()}) | ${escapeText(m.header?.summary ?? '').replace(/\|/g, '\\|')} |`).join('\n') + '\n')
writeFileSync(SIDEBAR, JSON.stringify(
  modules.map((m) => ({ text: `K.${m.name}`, link: `/api/${m.name.toLowerCase()}` })), null, 2) + '\n')

const count = modules.reduce((sum, m) => sum + m.functions.length + m.events.length +
  Object.values(m.methods).reduce((s, l) => s + l.length, 0), 0)
console.log(`API reference: ${modules.length} modules, ${count} entries`)
