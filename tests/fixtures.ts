/// The vocabulary the tests measure against.
///
/// Separate from the shipped seed on purpose, and the separation is the point.
///
/// Every term below is a real regression case: a word the recogniser was
/// measured mishearing on the original voice corpus, kept so the repair that
/// fixed it cannot quietly stop working. "grapify" for graphify, "Craig Eburn"
/// for Craigieburn, "Noah Kess" for Noah Kass — those are the actual outputs,
/// and a test fixture is exactly where they belong.
///
/// What they must NOT be is the list the app ships with. The seed used to be
/// this file, which meant every stranger who installed Quill received a
/// Dictionary containing a Melbourne suburb, a secondary school, and eleven
/// people by full name who never agreed to be in anybody's app.
export const FIXTURE_TERMS: string[] = [
  // Projects and tools said out loud
  'Quill', 'graphify', 'Nebula', 'Vesper', 'blockcraft', 'murmur',
  'mediadeck', 'originkit', 'shadcn', 'yt-dlp', 'tmux', 'xterm', 'node-pty',
  'Hammerspoon', 'pytest', 'venv', 'CPython', 'codesign', 'subagent', 'MCP',
  // Services and platforms
  'Firebase', 'Firestore', 'Netlify', 'Supabase', 'SQLite', 'Wispr Flow',
  'Airtasker', 'JB Hi-Fi', 'Baymard',
  // Apple, languages, type
  'SwiftUI', 'SwiftPM', 'Xcode', 'TypeScript', 'Playwright', 'Obsidian',
  'Ghostty', 'Sulkan', 'Fraunces', 'Space Grotesk',
  // Business
  'nxt', 'Next Fulfilment', 'Roman Design Co', 'Roman Design Studio',
  'Builda Bed', 'ABN', '3PL', 'glassmorphism', 'colourway', 'colourways',
  // Upholstery
  'Warwick', 'Kvadrat', 'Maharam', 'Martindale', 'Halgate',
  // Places
  'Craigieburn', 'Melbourne', 'Rosehill', 'Rosehill Secondary College',
  'Flinders Street',
  // People
  'Gigliotti', 'Carlo', 'Carlo Gigliotti', 'Noah Kass', 'Kass', 'Morello',
  'Ashwin Gupta', 'Ben McMullin', 'McMullin', 'Sara Chamberlain',
  'Rob Pisano', 'Lofree Hyzen',
];
