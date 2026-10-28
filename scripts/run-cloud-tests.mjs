// Runs the tests on Roblox servers through Open Cloud Luau execution.
//
//   node scripts/run-cloud-tests.mjs CorodeCI.rbxm
//
// Needs ROBLOX_API_KEY (scope: universe.place.luau-execution-session:write),
// ROBLOX_UNIVERSE_ID and ROBLOX_PLACE_ID. The model is sent as the task's binary
// input, so nothing is published and the place itself never changes.
import { readFileSync } from 'node:fs'

const API = 'https://apis.roblox.com/cloud/v2'
const POLL_SECONDS = 3
const GIVE_UP_SECONDS = 6 * 60

const { ROBLOX_API_KEY: apiKey, ROBLOX_UNIVERSE_ID: universeId, ROBLOX_PLACE_ID: placeId } = process.env
const modelPath = process.argv[2]
if (!apiKey || !universeId || !placeId || !modelPath) {
  console.error('Usage: ROBLOX_API_KEY=... ROBLOX_UNIVERSE_ID=... ROBLOX_PLACE_ID=... node scripts/run-cloud-tests.mjs <model.rbxm>')
  process.exit(2)
}

const sleep = (seconds) => new Promise((resolve) => setTimeout(resolve, seconds * 1000))

async function call(method, url, body) {
  for (let attempt = 1; ; attempt++) {
    const response = await fetch(url, {
      method,
      headers: { 'x-api-key': apiKey, 'content-type': 'application/json' },
      body: body && JSON.stringify(body),
    })
    // Creating tasks is limited to 5 a minute; wait and retry instead of failing the build.
    if (response.status === 429 && attempt < 5) {
      await sleep(15 * attempt)
      continue
    }
    const text = await response.text()
    if (!response.ok) {
      throw new Error(`${method} ${url} failed with ${response.status}: ${text}`)
    }
    return text ? JSON.parse(text) : {}
  }
}

const model = readFileSync(modelPath)
const input = await call('POST', `${API}/universes/${universeId}/luau-execution-session-task-binary-inputs`, { size: model.length })
const upload = await fetch(input.uploadUri, {
  method: 'PUT',
  headers: { 'content-type': 'application/octet-stream' },
  body: model,
})
if (!upload.ok) {
  throw new Error(`Uploading the model failed with ${upload.status}: ${await upload.text()}`)
}

const script = readFileSync(new URL('./cloud-test-task.luau', import.meta.url), 'utf8')
let task = await call('POST', `${API}/universes/${universeId}/places/${placeId}/luau-execution-session-tasks`, {
  script,
  binaryInput: input.path,
  timeout: '300s',
})
console.log(`Started ${task.path}`)

const started = Date.now()
while (!['COMPLETE', 'FAILED', 'CANCELLED'].includes(task.state)) {
  if (Date.now() - started > GIVE_UP_SECONDS * 1000) {
    throw new Error(`Gave up after ${GIVE_UP_SECONDS} seconds; the task is still ${task.state}.`)
  }
  await sleep(POLL_SECONDS)
  task = await call('GET', `${API}/${task.path}`)
}

try {
  const logs = await call('GET', `${API}/${task.path}/logs`)
  const messages = (logs.luauExecutionSessionTaskLogs ?? []).flatMap((entry) => entry.messages ?? [])
  if (messages.length) console.log('--- Output ---\n' + messages.join('\n'))
} catch (problem) {
  console.log(`(Couldn't read the logs: ${problem.message})`)
}

if (task.state !== 'COMPLETE') {
  console.error(`Task ${task.state}: ${JSON.stringify(task.error ?? task, null, 2)}`)
  process.exit(1)
}

const result = task.output?.results?.[0]
if (!result || typeof result.Failed !== 'number') {
  console.error(`The task finished without a test summary: ${JSON.stringify(task.output)}`)
  process.exit(1)
}
console.log('--- Tests ---\n' + result.Summary)
process.exit(result.Failed > 0 ? 1 : 0)
