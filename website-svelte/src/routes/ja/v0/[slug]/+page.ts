import { error } from '@sveltejs/kit';
import { processMarkdown } from '$lib/utils/markdown';
import { navV0Ja } from '$lib/nav';

export const prerender = true;

export const entries = () =>
	navV0Ja.flatMap(g => g.items).map(item => ({ slug: item.slug }));

export const load = async ({ params }) => {
	const { slug } = params;

	let raw: string;
	try {
		const mod = await import(`../../../../content/ja/v0/${slug}.md?raw`);
		raw = mod.default;
	} catch {
		error(404, `Page not found: ja/v0/${slug}`);
	}

	const { html, headings, title } = await processMarkdown(raw);
	return { html, headings, title, slug, version: 'v0' };
};
