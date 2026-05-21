<script lang="ts">
	import DocsLayout from '$lib/components/DocsLayout.svelte';
	import { navEn } from '$lib/nav';

	let { data } = $props();
</script>

<svelte:head>
	<title>{data.title || data.slug} — Amulet Docs</title>
</svelte:head>

<DocsLayout lang="en" nav={navEn} currentSlug={data.slug} headings={data.headings} title={data.title}>
	<div class="doc-meta">
		<span class="version-badge">v1.0.0 — current</span>
		<a class="v0-link" href="/v0/{data.slug}">v0.x (Zig) archived docs →</a>
	</div>
	{@html data.html}
</DocsLayout>

<style>
	.doc-meta {
		display: flex;
		align-items: center;
		gap: 1rem;
		margin-bottom: 1.25rem;
	}
	.version-badge {
		display: inline-block;
		font-size: 0.75rem;
		padding: 0.2rem 0.6rem;
		border-radius: 999px;
		border: 1px solid rgba(197, 160, 89, 0.35);
		color: #c5a059;
	}
	.v0-link {
		font-size: 0.75rem;
		color: rgba(197, 160, 89, 0.5);
		text-decoration: none;
	}
	.v0-link:hover {
		color: #c5a059;
	}
</style>
