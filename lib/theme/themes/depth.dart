/// Depth: dark glass, a violet and cyan pair of accents, and the focused
/// artwork's colour glowing behind the page. Built in, and written the same
/// way a shared theme file is (see ThemeSpec).
const depthThemeJson = <String, Object?>{
  'schema': 1,
  'id': 'depth',
  'name': 'Depth',
  'author': 'Kurage',
  'version': '0.1.0',
  'description': 'Dark glass and a glow from what you look at. Its fonts are Google Fonts: '
      'turn Google Fonts on to see them.',
  // Its own palette: the accent colour isn't offered; the background is
  // the theme's glow.
  'adjustable': ['cardSize', 'rowStyle'],
  'tokens': {
    'colors': {
      'background': '#06070b',
      'backgroundGlow': '#12142a',
      'surface': '#0e1018',
      'text': '#e8e9f0',
      'textMuted': '#9aa0b2',
      'accent': '#8f84ff',
      'accent2': '#8ee6f5',
      'star': '#ffc94d',
      'status': {
        'available': '#8ee6f5',
        'partiallyAvailable': '#8ee6f5',
        'pending': '#b9b2ff',
        'processing': '#ffc94d',
        'blocked': '#ff8a8a',
      },
    },
    'fonts': {'display': 'Bricolage Grotesque', 'ui': 'Manrope'},
    'radius': {'card': 16, 'panel': 26, 'menu': 16, 'button': 999},
    'glass': {'fill': 'rgba(10,11,18,.5)', 'border': 'rgba(255,255,255,.1)', 'blur': 18},
  },
  'components': {
    'app.backdrop': {'variant': 'glow', 'glow': 0.18, 'art': 0.16},
    'home.topBar': {'variant': 'pill'},
    'home.hero': {'variant': 'deck'},
    'home.row.continueWatching': {'variant': 'stage'},
    'home.row.nextUp': {'variant': 'shelf', 'kicker': 'Your queue'},
    'home.row.libraries': {'variant': 'doors', 'kicker': 'Step inside'},
    'home.row.genres': {'variant': 'flips', 'kicker': 'Find a mood'},
    'home.section': {'variant': 'drum'},
    'item.page': {'variant': 'feature'},
    'home.row.library': {'variant': 'byRow', 'kicker': 'Your picks'},
    'home.row.seerr': {'variant': 'tiles', 'kicker': 'From Seerr'},
    'home.row.recentlyAdded': {'variant': 'tiles', 'kicker': 'Just added'},
    'home.row.thisWeek': {'variant': 'timeline', 'kicker': 'On air'},
  },
  'devices': {
    // A PC: the programme hero, and the blurred art without the colour glow
    // (the desktop design's final pick; lighter to draw).
    'desktop': {
      'components': {
        'home.hero': {'variant': 'programme'},
        'app.backdrop': {'variant': 'glow', 'glow': 0, 'art': 0.16},
      },
    },
    'phone': {
      'tokens': {
        'radius': {'panel': 22},
      },
    },
    'tv': {
      'tokens': {
        'radius': {'panel': 36},
      },
      // Its own pass comes later; until then, the current page.
      'components': {
        'item.page': {'variant': 'classic'},
      },
    },
  },
};
