<script lang="ts">
	import DocsLayout from '$lib/components/DocsLayout.svelte';
	import { navEn } from '$lib/nav';

	let { data } = $props();
</script>

<svelte:head>
	<title>{data.title || data.slug} — Amulet Docs</title>
</svelte:head>

<DocsLayout lang="en" nav={navEn} currentSlug={data.slug} headings={data.headings} title={data.title}>
	<span class="version-badge">v1.0.0 — current</span>
	{@html data.html}
</DocsLayout>

<style>
	.version-badge {
		display: inline-block;
		font-size: 0.75rem;
		padding: 0.2rem 0.6rem;
		border-radius: 999px;
		border: 1px solid rgba(197, 160, 89, 0.35);
		color: #c5a059;
		margin-bottom: 1.25rem;
	}
</style>
