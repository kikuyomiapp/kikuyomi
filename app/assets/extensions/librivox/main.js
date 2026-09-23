// The LibriVox source extension, written against SourceAPI 1.0 (docs/source-api-1.0.md).
//
// LibriVox is a volunteer project that records public-domain books and puts the recordings in the
// public domain too, which is why it is the first source this app ships with (§3.10, §7.1). It has
// a read-only JSON API at librivox.org/api/feed/audiobooks/ and keeps its audio on the Internet
// Archive, so the manifest declares both hosts.
//
// One ES2020 file, no imports: this is what the SDK's bundler would produce, written by hand until
// the SDK exists. Everything it does goes through the host API on `globalThis.kikuyomi` (§3.5);
// there is no `fetch`, no filesystem and no device API to reach for.
//
// Things the API forces on an extension, and which the code below therefore has to handle:
//
//   * A search that matches nothing comes back as `{"error":"Audiobooks could not be found"}` with
//     status 200. That is an empty page, not a failure, for a list; asked for one book by id, it
//     means the book is gone, which is `NotFound`.
//   * `title=` matches a whole title; only `title=^x` matches a prefix. So every title search is
//     sent with the caret.
//   * A book's sections — its chapters — come only with `extended=1`, and then in the same response
//     as its details, so `getBookDetails` and `getChapters` would fetch the same document twice.
//     One entry is memoised for a minute to spare LibriVox the second request.
//   * Descriptions are HTML. The contract wants plain text with its line breaks kept, so the markup
//     is unwound here rather than shown to the listener.
//   * `language` is a name such as "English", which is not a BCP 47 tag. The app drops a tag it
//     cannot read, so the names LibriVox uses are mapped to tags and anything else is left out.
//   * There is no cover in the API at all. Every LibriVox project is an Internet Archive item, and
//     that item's identifier can be read out of `url_iarchive` or `url_zip_file`; the Archive
//     serves each item's art at /services/img/<identifier>.
//
// What it does not do: LibriVox's API has no "recently added, newest first" order, so there is no
// `getLatest`; and its audio needs no headers or cookies, so there is no `getImageRequest` either.
// The manifest declares neither.

'use strict';

/** The one endpoint this extension reads. Everything else it returns points at the Archive. */
var API = 'https://librivox.org/api/feed/audiobooks/';

/** How many books one page of results holds. The contract allows 200; 50 is a screenful to scroll
 *  through and a tenth of the bytes. */
var PAGE_SIZE = 50;

/** The fields a list needs. The API returns the full description for every book otherwise, which is
 *  most of the payload and nothing a grid of covers shows. */
var LIST_FIELDS = '{id,title,authors,totaltimesecs,url_zip_file}';

/** How long one book's extended document is kept, so that `getChapters` after `getBookDetails`
 *  costs LibriVox nothing. Short, because a refresh a minute later should see the site again. */
var BOOK_MEMO_MS = 60000;

// ---------------------------------------------------------------------------------------- errors

/**
 * One of the contract's error kinds, as a thrown value.
 *
 * The SDK will export these as classes. Until it does, the shape is what matters: the app reads
 * `kind` off whatever is thrown and reacts to it (§3.4), and anything it cannot read is `Parse`.
 */
function sourceError(kind, message, extra) {
  var error = new Error(message);
  error.kind = kind;
  if (extra) {
    for (var field in extra) {
      if (Object.prototype.hasOwnProperty.call(extra, field)) error[field] = extra[field];
    }
  }
  return error;
}

// ------------------------------------------------------------------------------------- reading

/** A value as trimmed text, or '' for anything that is not text worth keeping. */
function textOf(value) {
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number' && isFinite(value)) return String(value);
  return '';
}

/**
 * Seconds, as LibriVox writes them, in milliseconds; undefined when there is no usable figure.
 *
 * The API gives `playtime` as a string and `totaltimesecs` as a number, and either can be 0 or
 * missing for a project whose files were never timed. The contract reads a duration of 0 as "not
 * known", so leaving it out says the same thing more plainly.
 */
function msFromSeconds(value) {
  var seconds = typeof value === 'number' ? value : parseInt(textOf(value), 10);
  if (!isFinite(seconds) || seconds <= 0) return undefined;
  return Math.round(seconds) * 1000;
}

/** The named entities LibriVox summaries actually use, plus the five every HTML document may. */
var ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'",
  nbsp: ' ', hellip: '…', mdash: '—', ndash: '–',
  lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”',
  laquo: '«', raquo: '»', deg: '°', middot: '·',
  eacute: 'é', egrave: 'è', agrave: 'à', ccedil: 'ç',
  uuml: 'ü', ouml: 'ö', auml: 'ä', szlig: 'ß',
  ntilde: 'ñ', copy: '©', reg: '®', trade: '™'
};

function decodeEntities(text) {
  return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, function (whole, body) {
    if (body.charAt(0) === '#') {
      var hex = body.charAt(1) === 'x' || body.charAt(1) === 'X';
      var code = parseInt(hex ? body.slice(2) : body.slice(1), hex ? 16 : 10);
      if (!isFinite(code) || code < 0 || code > 0x10ffff) return whole;
      try {
        return String.fromCodePoint(code);
      } catch (error) {
        return whole;
      }
    }
    var named = ENTITIES[body];
    return named === undefined ? whole : named;
  });
}

/**
 * A LibriVox summary as the plain text the contract wants, or undefined when there is none.
 *
 * The markup is unwound here rather than through `kikuyomi.html.parse`, for one reason: the host's
 * `text()` collapses all whitespace, and these summaries are paragraphs separated by `<br />` whose
 * breaks are worth keeping. So block ends become newlines, tags go, entities are decoded, and what
 * is left is tidied line by line.
 *
 * Control characters are taken out because the contract refuses a description that holds one —
 * newlines excepted, which are exactly what this is preserving. The 20,000-character limit is
 * applied here too, cutting rather than letting the whole call fail over a long summary.
 */
function plainText(value) {
  var html = textOf(value);
  if (!html) return undefined;
  var text = html
    .replace(/\r\n?/g, '\n')
    .replace(/<\s*br\s*\/?\s*>/gi, '\n')
    .replace(/<\s*\/\s*(p|div|li|tr|h[1-6]|blockquote)\s*>/gi, '\n')
    .replace(/<[^>]*>/g, '');
  text = decodeEntities(text);
  // Every control character but the newlines just introduced becomes a space.
  text = text.replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, ' ');
  var lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    lines[i] = lines[i].replace(/\s+/g, ' ').trim();
  }
  text = lines.join('\n').replace(/\n{3,}/g, '\n\n').trim();
  if (text.length > 20000) text = text.slice(0, 20000).trim();
  return text || undefined;
}

/**
 * The names LibriVox writes against `language`, as BCP 47 tags.
 *
 * Only the ones it really uses. A name that is not here is left out of the result rather than
 * guessed at: the app would drop "Old English" anyway, and a wrong tag would put a book in the
 * wrong language filter for good.
 */
var LANGUAGES = {
  afrikaans: 'af', albanian: 'sq', arabic: 'ar', armenian: 'hy', bengali: 'bn',
  bulgarian: 'bg', catalan: 'ca', chinese: 'zh', croatian: 'hr', czech: 'cs',
  danish: 'da', dutch: 'nl', english: 'en', esperanto: 'eo', estonian: 'et',
  finnish: 'fi', french: 'fr', frisian: 'fy', galician: 'gl', georgian: 'ka',
  german: 'de', greek: 'el', 'ancient greek': 'grc', gujarati: 'gu', hebrew: 'he',
  hindi: 'hi', hungarian: 'hu', icelandic: 'is', indonesian: 'id', irish: 'ga',
  italian: 'it', japanese: 'ja', kannada: 'kn', korean: 'ko', latin: 'la',
  latvian: 'lv', lithuanian: 'lt', macedonian: 'mk', malay: 'ms', malayalam: 'ml',
  marathi: 'mr', mongolian: 'mn', nepali: 'ne', norwegian: 'no', 'old english': 'ang',
  persian: 'fa', polish: 'pl', portuguese: 'pt', romanian: 'ro', russian: 'ru',
  sanskrit: 'sa', serbian: 'sr', slovak: 'sk', slovenian: 'sl', spanish: 'es',
  swahili: 'sw', swedish: 'sv', tagalog: 'tl', tamil: 'ta', telugu: 'te',
  thai: 'th', turkish: 'tr', ukrainian: 'uk', urdu: 'ur', vietnamese: 'vi',
  welsh: 'cy', yiddish: 'yi'
};

function languageTagOf(value) {
  var name = textOf(value).toLowerCase();
  return name ? LANGUAGES[name] : undefined;
}

/** An author as one name: LibriVox splits them, and either half can be empty ("Various"). */
function personName(person) {
  if (!person || typeof person !== 'object') return '';
  return (textOf(person.first_name) + ' ' + textOf(person.last_name)).replace(/\s+/g, ' ').trim();
}

function authorsOf(book) {
  var names = [];
  var authors = Array.isArray(book.authors) ? book.authors : [];
  for (var i = 0; i < authors.length; i++) {
    var name = personName(authors[i]);
    if (name && names.indexOf(name) < 0) names.push(name);
  }
  return names;
}

/**
 * The readers of a book, in the order they are first credited.
 *
 * LibriVox credits readers per section, not per book, so this is the only place a book's narrators
 * come from — and the reason `getBookDetails` asks for the extended document.
 */
function narratorsOf(book) {
  var names = [];
  var sections = Array.isArray(book.sections) ? book.sections : [];
  for (var i = 0; i < sections.length; i++) {
    var readers = sections[i] && Array.isArray(sections[i].readers) ? sections[i].readers : [];
    for (var j = 0; j < readers.length; j++) {
      var name = textOf(readers[j] && readers[j].display_name);
      if (name && names.indexOf(name) < 0) names.push(name);
    }
  }
  return names;
}

/**
 * The cover the Internet Archive serves for this book's item, or undefined when the item cannot be
 * named.
 *
 * `url_iarchive` carries the item outright but only comes with `extended=1`; `url_zip_file` carries
 * it in every response, which is why a list can show covers at all.
 */
function coverUrlOf(book) {
  var identifier = archiveItemOf(book.url_iarchive, '/details/') ||
    archiveItemOf(book.url_zip_file, '/compress/');
  return identifier ? 'https://archive.org/services/img/' + identifier : undefined;
}

function archiveItemOf(value, marker) {
  var url = textOf(value);
  var at = url.indexOf(marker);
  if (at < 0) return '';
  var rest = url.slice(at + marker.length);
  var end = rest.search(/[\/?#]/);
  var identifier = end < 0 ? rest : rest.slice(0, end);
  // Archive identifiers are letters, digits, dots, dashes and underscores. Anything else means the
  // URL was not the shape this reads, and inventing a cover URL from it would only ask the app to
  // fetch something that is not there.
  return /^[A-Za-z0-9._-]+$/.test(identifier) ? identifier : '';
}

/** The file a section's audio lives in, named by the file itself so two sections cut from one file
 *  would share it. */
function fileKeyOf(url) {
  var withoutQuery = url.split('#')[0].split('?')[0];
  var name = withoutQuery.slice(withoutQuery.lastIndexOf('/') + 1);
  return name || url;
}

/** What the file's extension says it is, in the contract's vocabulary. LibriVox serves MP3. */
function formatOf(url) {
  var name = fileKeyOf(url).toLowerCase();
  if (/\.mp3$/.test(name)) return 'mp3';
  if (/\.m4b$/.test(name)) return 'm4b';
  if (/\.m4a$/.test(name)) return 'm4a';
  if (/\.ogg$/.test(name)) return 'ogg';
  if (/\.opus$/.test(name)) return 'opus';
  if (/\.flac$/.test(name)) return 'flac';
  return undefined;
}

// ------------------------------------------------------------------------------------- fetching

/**
 * One GET of the API, as JSON.
 *
 * `http.fetch` returns any status rather than throwing, so the statuses that mean something are
 * read here: 429 is the site asking to be left alone, 5xx is the site being unwell, and anything
 * else unexpected is reported as `Parse` because the extension cannot read it. Only a failure to
 * connect throws by itself, already as `Network`.
 */
async function getJson(url) {
  var response = await kikuyomi.http.fetch({ url: url, responseType: 'json' });
  var status = response.status;
  if (status === 429 || status === 503) {
    var after = parseInt(textOf(response.headers && response.headers['retry-after']), 10);
    throw sourceError('RateLimited', 'librivox.org asked for a pause (' + status + ')',
      isFinite(after) && after > 0 ? { retryAfterMs: after * 1000 } : null);
  }
  if (status === 404) throw sourceError('NotFound', 'librivox.org has nothing at ' + url);
  if (status >= 500) throw sourceError('Network', 'librivox.org answered ' + status);
  if (status !== 200) {
    throw sourceError('Parse', 'librivox.org answered ' + status + ' for ' + url);
  }
  var body = response.body;
  if (!body || typeof body !== 'object') {
    throw sourceError('Parse', 'the answer from librivox.org is not an object');
  }
  return body;
}

/**
 * The books in a list response.
 *
 * A list that matches nothing comes back as `{"error":"Audiobooks could not be found"}`, which is
 * an empty page: a search for a word no title holds is a normal thing to do, not a failure.
 */
function booksInList(body) {
  if (Array.isArray(body.books)) return body.books;
  if (typeof body.error === 'string') return [];
  throw sourceError('Parse', 'librivox.org answered without a list of books');
}

function listUrl(query, page) {
  var offset = (page - 1) * PAGE_SIZE;
  return API + '?format=json&limit=' + PAGE_SIZE + '&offset=' + offset +
    '&fields=' + encodeURIComponent(LIST_FIELDS) + query;
}

/** One page of a list, as the contract's `PageResult<BookSummary>`. */
async function listPage(query, page) {
  var books = booksInList(await getJson(listUrl(query, page)));
  return { items: summariesOf(books), hasNextPage: books.length >= PAGE_SIZE };
}

function summariesOf(books) {
  var items = [];
  for (var i = 0; i < books.length; i++) {
    var summary = summaryOf(books[i]);
    if (summary) items.push(summary);
  }
  return items;
}

/**
 * One book as a list row, or null when it cannot be identified.
 *
 * A row without an id or a title is left out rather than failing the page: one unreadable entry in
 * a catalogue of twenty thousand should not cost the listener the other forty-nine.
 */
function summaryOf(book) {
  if (!book || typeof book !== 'object') return null;
  var key = textOf(book.id);
  var title = textOf(book.title);
  if (!key || !title) {
    kikuyomi.log.warn('skipping a book with no id or title');
    return null;
  }
  return {
    key: key,
    title: title,
    coverUrl: coverUrlOf(book),
    authors: authorsOf(book),
    durationMs: msFromSeconds(book.totaltimesecs)
  };
}

/**
 * One book's extended document: its details and its sections in one response.
 *
 * Memoised for a minute and one book deep, because the app asks for details and then for chapters,
 * and again for the audio of the chapter it plays first. Nothing else is kept between calls: the
 * runtime belongs to the extension for as long as the app is running, and a cache that grows with
 * the catalogue would be a leak.
 */
var memo = null;

async function bookById(bookKey) {
  var key = textOf(bookKey);
  if (!key) throw sourceError('NotFound', 'a LibriVox book is named by its id');
  var now = Date.now();
  if (memo && memo.key === key && now - memo.at < BOOK_MEMO_MS) return memo.book;
  var body = await getJson(API + '?format=json&extended=1&id=' + encodeURIComponent(key));
  var books = Array.isArray(body.books) ? body.books : [];
  // Asked for one book by id, "could not be found" means exactly that.
  if (!books.length || !books[0] || typeof books[0] !== 'object') {
    throw sourceError('NotFound', 'LibriVox has no book ' + key);
  }
  memo = { key: key, at: now, book: books[0] };
  return books[0];
}

function sectionsOf(book) {
  return Array.isArray(book.sections) ? book.sections : [];
}

// --------------------------------------------------------------------------------------- source

/**
 * Which of LibriVox's three search parameters a query goes to.
 *
 * `everything` asks by title and by author and puts the two together, because someone typing
 * "Melville" means the author and someone typing "Moby" means the title, and the API will not do
 * both at once. Each page asks both at the same offset, so paging stays consistent: page two is
 * the second fifty of each list, never a re-shuffle of the first.
 */
var SEARCH_FIELD = 'field';

function chosenField(query) {
  var filters = query && query.filters;
  var chosen = filters ? textOf(filters[SEARCH_FIELD]) : '';
  return chosen === 'title' || chosen === 'author' || chosen === 'genre' ? chosen : 'everything';
}

/** `title=^x` matches titles beginning with x; `title=x` matches only the whole title. */
function titleQuery(text) {
  return '&title=' + encodeURIComponent('^' + text);
}

function authorQuery(text) {
  return '&author=' + encodeURIComponent('^' + text);
}

var librivox = {
  async getPopular(page) {
    // LibriVox ranks nothing, and its API offers no order but its own, which runs from the oldest
    // catalogued project onwards. That order begins with the recordings the project is known for —
    // Monte Cristo, Huckleberry Finn, Frankenstein, Moby Dick — so it is the closest thing to
    // "popular" the site can honestly answer, and it is stable, which paging needs.
    return listPage('', page);
  },

  getFilters() {
    return [
      { kind: 'header', label: 'Search LibriVox' },
      {
        kind: 'select',
        key: SEARCH_FIELD,
        label: 'Look in',
        options: [
          { value: 'everything', label: 'Titles and authors' },
          { value: 'title', label: 'Titles' },
          { value: 'author', label: 'Authors' },
          { value: 'genre', label: 'Genre' }
        ],
        default: 'everything'
      }
    ];
  },

  async search(query, page) {
    var text = textOf(query && query.text);
    // Only filters are set, and none of them narrows a listing on its own: show the catalogue.
    if (!text) return listPage('', page);
    var field = chosenField(query);
    if (field === 'title') return listPage(titleQuery(text), page);
    if (field === 'author') return listPage(authorQuery(text), page);
    if (field === 'genre') return listPage('&genre=' + encodeURIComponent(text), page);

    var byTitle = booksInList(await getJson(listUrl(titleQuery(text), page)));
    var byAuthor = booksInList(await getJson(listUrl(authorQuery(text), page)));
    var items = summariesOf(byTitle);
    // A bare object, not `{}`: a book key is a string a source chose, and on an ordinary object the
    // keys `__proto__` and `constructor` would answer for themselves. LibriVox only ever gives
    // numbers, but this file is the one extension authors will copy.
    var seen = Object.create(null);
    for (var i = 0; i < items.length; i++) seen[items[i].key] = true;
    var authored = summariesOf(byAuthor);
    for (var j = 0; j < authored.length; j++) {
      if (!seen[authored[j].key]) {
        seen[authored[j].key] = true;
        items.push(authored[j]);
      }
    }
    return {
      items: items,
      hasNextPage: byTitle.length >= PAGE_SIZE || byAuthor.length >= PAGE_SIZE
    };
  },

  async getBookDetails(bookKey) {
    var book = await bookById(bookKey);
    var title = textOf(book.title);
    if (!title) throw sourceError('Parse', 'book ' + bookKey + ' has no title');
    var genres = [];
    var listed = Array.isArray(book.genres) ? book.genres : [];
    for (var i = 0; i < listed.length; i++) {
      var name = textOf(listed[i] && listed[i].name);
      if (name && genres.indexOf(name) < 0) genres.push(name);
    }
    return {
      key: textOf(book.id) || textOf(bookKey),
      title: title,
      authors: authorsOf(book),
      narrators: narratorsOf(book),
      description: plainText(book.description),
      coverUrl: coverUrlOf(book),
      genres: genres,
      language: languageTagOf(book.language),
      // The recording is LibriVox's; the text is whatever the volunteers read from.
      publisher: 'LibriVox',
      // LibriVox gives the year the text was published, not the year it was recorded.
      publishedDate: textOf(book.copyright_year) || undefined,
      totalDurationMs: msFromSeconds(book.totaltimesecs),
      // A LibriVox project is catalogued only once every section has been recorded and checked, so
      // a book in the API is always finished. Nothing there is ever released a chapter at a time.
      status: 'complete',
      webUrl: textOf(book.url_librivox) || undefined
    };
  },

  async getChapters(bookKey) {
    var book = await bookById(bookKey);
    var sections = sectionsOf(book);
    var chapters = [];
    for (var i = 0; i < sections.length; i++) {
      var section = sections[i];
      if (!section || typeof section !== 'object') continue;
      var key = textOf(section.id);
      if (!key) {
        kikuyomi.log.warn('skipping a section of book ' + bookKey + ' with no id');
        continue;
      }
      chapters.push({
        key: key,
        // Some sections are catalogued without a title; their number is what the site shows.
        title: textOf(section.title) ||
          ('Section ' + (textOf(section.section_number) || String(i + 1))),
        durationMs: msFromSeconds(section.playtime)
      });
    }
    if (!chapters.length) {
      throw sourceError('NotFound', 'LibriVox lists no sections for book ' + bookKey);
    }
    return chapters;
  },

  async resolveMedia(chapter) {
    var book = await bookById(chapter && chapter.bookKey);
    var sections = sectionsOf(book);
    var wanted = textOf(chapter && chapter.chapterKey);
    var section = null;
    for (var i = 0; i < sections.length; i++) {
      if (sections[i] && textOf(sections[i].id) === wanted) {
        section = sections[i];
        break;
      }
    }
    if (!section) {
      throw sourceError('NotFound', 'book ' + textOf(chapter && chapter.bookKey) +
        ' has no section ' + wanted);
    }
    var url = textOf(section.listen_url);
    if (!url) {
      throw sourceError('NotFound', 'section ' + wanted + ' has no audio at the Archive yet');
    }
    // One section is one file on the Internet Archive, played whole, so there is no range. The
    // Archive serves these files from a fixed address with no token and no expiry, so there is no
    // `expiresAt` either: the app may keep this resolution for as long as it likes.
    return {
      segments: [
        {
          fileKey: fileKeyOf(url),
          request: { url: url },
          format: formatOf(url),
          durationMs: msFromSeconds(section.playtime)
        }
      ]
    };
  }
};

module.exports = { sources: { librivox: librivox } };
