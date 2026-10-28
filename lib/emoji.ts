// The built-in emoji table from the app (lib/emoji.ts), trimmed to the list. tests/sql/stage24x checks the
// database's reaction_emoji_ok against it.

/** Built-in emojis shown in the picker, with search keywords. */
export const STANDARD: [string, string][] = [
  ['😀', 'grinning smile happy'], ['😂', 'joy laugh crying'], ['🤣', 'rofl rolling laugh'], ['😊', 'blush smile'],
  ['😍', 'heart eyes love'], ['🥰', 'smiling hearts love'], ['😘', 'kiss'], ['😎', 'cool sunglasses'],
  ['🤔', 'thinking hmm'], ['🙄', 'eye roll'], ['😏', 'smirk'], ['😴', 'sleeping tired'],
  ['😭', 'sob crying'], ['😡', 'angry rage'], ['🤯', 'mind blown exploding'], ['😱', 'scream shock'],
  ['🥺', 'pleading puppy eyes'], ['😬', 'grimace awkward'], ['🤡', 'clown'], ['💀', 'skull dead'],
  ['👻', 'ghost'], ['🤖', 'robot'], ['👽', 'alien'], ['💩', 'poop'],
  ['🙃', 'upside down'], ['😇', 'angel halo'], ['🤠', 'cowboy'], ['🥳', 'party celebrate'],
  ['😤', 'triumph huff'], ['🤫', 'shush quiet'], ['🫡', 'salute'], ['🫠', 'melting'],
  ['👍', 'thumbs up yes like'], ['👎', 'thumbs down no'], ['👏', 'clap'], ['🙌', 'raised hands'],
  ['🙏', 'pray please thanks'], ['👋', 'wave hi bye'], ['🤝', 'handshake deal'], ['💪', 'muscle strong'],
  ['✌️', 'peace victory'], ['🤞', 'fingers crossed luck'], ['👀', 'eyes looking'], ['🧠', 'brain smart'],
  ['❤️', 'red heart love'], ['🧡', 'orange heart'], ['💛', 'yellow heart'], ['💚', 'green heart'],
  ['💙', 'blue heart'], ['💜', 'purple heart'], ['🖤', 'black heart'], ['💔', 'broken heart'],
  ['🔥', 'fire lit hot'], ['✨', 'sparkles'], ['⭐', 'star'], ['💯', 'hundred perfect'],
  ['✅', 'check yes done'], ['❌', 'cross no wrong'], ['⚠️', 'warning'], ['❓', 'question'],
  ['🎉', 'tada party'], ['🎮', 'video game controller'], ['🏆', 'trophy win'], ['🎵', 'music note'],
  ['📢', 'loudspeaker announcement'], ['💬', 'speech bubble yap'], ['📸', 'camera photo'], ['💻', 'laptop computer'],
  ['🐀', 'rat'], ['🐁', 'mouse'], ['🐶', 'dog'], ['🐱', 'cat'], ['🐸', 'frog'], ['🐒', 'monkey'],
  ['🦆', 'duck'], ['🐟', 'fish'], ['🦄', 'unicorn'], ['🐍', 'snake'], ['🦀', 'crab'], ['🐧', 'penguin'],
  ['🍕', 'pizza'], ['🍔', 'burger'], ['🍟', 'fries'], ['🌮', 'taco'], ['🍩', 'donut'], ['🍪', 'cookie'],
  ['☕', 'coffee'], ['🧃', 'juice box'], ['🍿', 'popcorn'], ['🧀', 'cheese'],
  ['🚀', 'rocket'], ['💸', 'money flying'], ['💰', 'money bag'], ['🗿', 'moai stone face'],
  ['🌈', 'rainbow'], ['☀️', 'sun'], ['🌙', 'moon'], ['⚡', 'lightning zap'],
  ['🏳️‍🌈', 'pride rainbow flag lgbt lgbtq gay'], ['🏳️‍⚧️', 'trans transgender flag pride lgbtq'], ['🏳️', 'whiteflag white flag surrender'], ['🏴', 'blackflag black flag'],
  ['🏴‍☠️', 'pirate flag skull'], ['🏁', 'checkered flag race finish'], ['🚩', 'redflag red flag'], ['🎌', 'crossedflags crossed flags japan'],
  ['🇺🇸', 'us usa america united states flag'], ['🇬🇧', 'gb uk britain england united kingdom flag'], ['🇨🇦', 'canada flag'], ['🇦🇺', 'australia flag'],
  ['🇩🇪', 'germany deutschland flag'], ['🇫🇷', 'france flag'], ['🇪🇸', 'spain espana flag'], ['🇮🇹', 'italy italia flag'],
  ['🇳🇱', 'netherlands holland dutch flag'], ['🇵🇱', 'poland polska flag'], ['🇨🇿', 'czechia czech republic flag'], ['🇸🇰', 'slovakia flag'],
  ['🇺🇦', 'ukraine flag'], ['🇧🇷', 'brazil brasil flag'], ['🇲🇽', 'mexico flag'], ['🇮🇳', 'india flag'],
  ['🇯🇵', 'japan flag'], ['🇰🇷', 'korea south korea flag'], ['🇨🇳', 'china flag'], ['🇹🇷', 'turkey turkiye flag'],
  ['🇸🇪', 'sweden flag'], ['🇳🇴', 'norway flag'], ['🇫🇮', 'finland flag'], ['🇮🇪', 'ireland flag'],
  ['🇵🇹', 'portugal flag'], ['🇷🇺', 'russia flag'], ['🇪🇺', 'eu europe european union flag'], ['🇺🇳', 'un united nations flag'],
];

/** What an emoji pick is stored as where only one emoji lives (reaction roles, onboarding answers): the <:name:id> token for a custom one, the emoji itself otherwise. */
export const pickedEmojiKey = (p: { text: string; custom?: { id: string; name: string; animated: boolean } }) =>
  (p.custom ? `<${p.custom.animated ? 'a' : ''}:${p.custom.name}:${p.custom.id}>` : p.text);

/** Custom emojis are stored in messages as <:name:id> (or <a:name:id> if animated). */
