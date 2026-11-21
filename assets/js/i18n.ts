// UI text and number formatting for client-rendered strings. Numbers follow the regional format,
// `<html data-locale>`; plurals follow the UI language, `<html lang>` (both `Mythweaver.Locale`).
// The text is `MythweaverWeb.ClientStrings.catalog/0`, translated on the server and encoded into
// `<body data-client-strings>`.

type Plural = Record<string, string>;
type Catalog = Record<string, string | Plural>;

let catalog: Catalog | null = null;

const strings = (): Catalog =>
  (catalog ??= JSON.parse(document.body.dataset.clientStrings ?? "{}") as Catalog);

const fill = (template: string, bindings: Record<string, string | number>): string =>
  template.replace(/%\{(\w+)\}/g, (match, name: string) =>
    name in bindings ? String(bindings[name]) : match,
  );

/** The page's regional format for `Intl` number and date formatting, or undefined (the browser's). */
export const locale = (): string | undefined => document.documentElement.dataset.locale || undefined;

/** The page's UI language, for plural rules. */
const language = (): string | undefined => document.documentElement.lang || undefined;

/** The translated string `key` with its `%{name}` placeholders filled; the key itself if unknown. */
export const t = (key: string, bindings: Record<string, string | number> = {}): string => {
  const template = strings()[key];
  return typeof template === "string" ? fill(template, bindings) : key;
};

/**
 * The plural string `key` for `n`, picked by `n`'s CLDR category in the UI language (falling back
 * to "other"), with `placeholder` bound to `n` formatted in the regional format.
 */
export const tn = (key: string, n: number, placeholder: string): string => {
  const forms = strings()[key];
  if (forms == null || typeof forms === "string") return key;
  const template = forms[new Intl.PluralRules(language()).select(n)] ?? forms.other;
  return template == null
    ? key
    : fill(template, { [placeholder]: new Intl.NumberFormat(locale()).format(n) });
};
