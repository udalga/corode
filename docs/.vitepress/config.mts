import { defineConfig } from 'vitepress'
// Written by scripts/gen-api.mjs from the Luau sources.
import apiSidebar from './api-sidebar.json'

export default defineConfig({
  title: 'Corode',
  description: 'One Roblox framework for currencies, items, combat, NPCs, quests, shops, UI and more.',
  lang: 'en-US',
  // Served from https://udalga.github.io/corode/
  base: '/corode/',
  cleanUrls: true,
  lastUpdated: false,
  head: [['meta', { name: 'theme-color', content: '#00a2ff' }]],
  markdown: {
    theme: { light: 'github-light', dark: 'github-dark' },
  },
  themeConfig: {
    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Systems', link: '/systems/currency-data' },
      { text: 'API', link: '/api/' },
      { text: 'Security', link: '/reference/security' },
    ],
    sidebar: {
      '/api/': [
        { text: 'API reference', link: '/api/' },
        { text: 'Modules', items: apiSidebar },
      ],
      '/': [
        {
          text: 'Guide',
          items: [
            { text: 'Getting started', link: '/guide/getting-started' },
            { text: 'Core ideas', link: '/guide/core-ideas' },
            { text: 'When', link: '/guide/when' },
          ],
        },
        {
          text: 'Building blocks',
          items: [
            { text: 'Values', link: '/blocks/values' },
            { text: 'Actions and Hooks', link: '/blocks/actions' },
            { text: 'Tags', link: '/blocks/tags' },
            { text: 'Shared values and Timers', link: '/blocks/shared-timers' },
            { text: 'Machines', link: '/blocks/machines' },
          ],
        },
        {
          text: 'Gameplay',
          items: [
            { text: 'Currency, Leaderstats and Data', link: '/systems/currency-data' },
            { text: 'Items and Inventory', link: '/systems/items-inventory' },
            { text: 'Stats and Combat', link: '/systems/stats-combat' },
            { text: 'NPC', link: '/systems/npc' },
            { text: 'Quests and Rewards', link: '/systems/quests-rewards' },
            { text: 'Rounds and Teams', link: '/systems/rounds-teams' },
          ],
        },
        {
          text: 'Platform',
          items: [
            { text: 'Shop', link: '/platform/shop' },
            { text: 'Global', link: '/platform/global' },
            { text: 'AntiCheat and Admin', link: '/platform/anticheat-admin' },
            { text: 'Analytics', link: '/platform/analytics' },
          ],
        },
        {
          text: 'Client',
          items: [{ text: 'UI and Input', link: '/client/ui-input' }],
        },
        {
          text: 'Reference',
          items: [
            { text: 'Utilities', link: '/reference/utilities' },
            { text: 'Security checklist', link: '/reference/security' },
            { text: 'API reference', link: '/api/' },
            { text: 'Working on Corode', link: '/reference/contributing' },
          ],
        },
      ],
    },
    outline: { level: [2, 3], label: 'On this page' },
    search: { provider: 'local' },
    docFooter: { prev: 'Previous', next: 'Next' },
    footer: { message: 'Corode 0.10.0' },
  },
})
