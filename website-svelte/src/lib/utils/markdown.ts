import { unified } from 'unified';
import { addTableDataLabels } from './tableLabels';
import remarkParse from 'remark-parse';
import remarkGfm from 'remark-gfm';
import remarkRehype from 'remark-rehype';
import rehypeSlug from 'rehype-slug';
import rehypeStringify from 'rehype-stringify';
import { createHighlighter } from 'shiki';

let highlighter: Awaited<ReturnType<typeof createHighlighter>> | null = null;

async function getHighlighter() {
	if (!highlighter) {
		highlighter = await createHighlighter({
			themes: ['tokyo-night'],
			langs: ['bash', 'sh', 'powershell', 'typescript', 'javascript', 'json', 'yaml', 'toml', 'ini', 'text']
		});
	}
	return highlighter;
}

export interface Heading {
	id: string;
	text: string;
	level: number;
}

export interface MarkdownResult {
	html: string;
	headings: Heading[];
	title: string;
}

function extractTitle(raw: string): string {
	const m = raw.match(/^---[\s\S]*?^title:\s*["']?(.+?)["']?\s*$/m);
	return m ? m[1].trim() : '';
}

function stripFrontmatter(raw: string): string {
	return raw.replace(/^---[\s\S]*?---\n?/, '');
}

function convertAdmonitions(raw: string): string {
	return raw.replace(
		/^:::\s*(note|tip|caution|danger|warning|info)\n([\s\S]*?)^:::\s*$/gm,
		(_, type, content) => {
			const cls = type === 'warning' ? 'admonition-caution' : type === 'info' ? 'admonition-note' : `admonition-${type}`;
			return `\n\n<div class="admonition ${cls}">\n\n${content.trim()}\n\n</div>\n\n`;
		}
	);
}

export async function processMarkdown(raw: string): Promise<MarkdownResult> {
	const hl = await getHighlighter();
	const headings: Heading[] = [];
	const title = extractTitle(raw);

	raw = stripFrontmatter(raw);
	raw = convertAdmonitions(raw);

	// Replace fenced code blocks with shiki-highlighted HTML before remark processing
	const withHighlightedCode = raw.replace(
		/```(\w*)\n([\s\S]*?)```/g,
		(_, lang, code) => {
			const language = lang || 'text';
			const availableLangs = ['bash', 'sh', 'powershell', 'typescript', 'javascript', 'json', 'yaml', 'toml', 'ini', 'text'];
			const useLang = availableLangs.includes(language) ? language : 'text';
			const highlighted = hl.codeToHtml(code.trimEnd(), {
				lang: useLang,
				theme: 'tokyo-night'
			});
			return `\n\n<div class="code-block">${highlighted}</div>\n\n`;
		}
	);

	const result = await unified()
		.use(remarkParse)
		.use(remarkGfm)
		.use(remarkRehype, { allowDangerousHtml: true })
		.use(rehypeSlug)
		.use(rehypeStringify, { allowDangerousHtml: true })
		.process(withHighlightedCode);

	const rawHtml = addTableDataLabels(
		String(result)
			.replace(/<table>/g, '<div class="table-wrap"><table>')
			.replace(/<\/table>/g, '</table></div>')
	);

	// Extract headings from processed HTML so IDs always match rehype-slug output
	const headingHtmlRe = /<h([1-6])[^>]*\s+id="([^"]+)"[^>]*>([\s\S]*?)<\/h[1-6]>/g;
	let hm;
	while ((hm = headingHtmlRe.exec(rawHtml)) !== null) {
		const level = parseInt(hm[1]);
		const id = hm[2];
		const text = hm[3].replace(/<[^>]+>/g, '').trim();
		headings.push({ id, text, level });
	}

	return { html: rawHtml, headings, title };
}
