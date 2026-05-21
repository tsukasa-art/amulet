<script lang="ts">
	import DocsLayout from '$lib/components/DocsLayout.svelte';
	import { navV0En } from '$lib/nav';

	let { data } = $props();
</script>

<svelte:head>
	<title>{data.title || data.slug} — Amulet v0 Docs (archived)</title>
</svelte:head>

<DocsLayout lang="en" nav={navV0En} currentSlug={data.slug} headings={data.headings} title={data.title}>
	<div class="archived-banner">
		⚠️ This is archived documentation for Amulet v0.x (Zig implementation).
		<a href="/{data.slug}">View current v1.0.0 docs →</a>
	</div>
	{@html data.html}
</DocsLayout>

<style>
	.archived-banner {
		background: rgba(197, 160, 89, 0.08);
		border: 1px solid rgba(197, 160, 89, 0.4);
		border-radius: 6px;
		padding: 0.75rem 1rem;
		margin-bottom: 1.5rem;
		font-size: 0.9rem;
		color: #c5a059;
	}
	.archived-banner a {
		margin-left: 0.5rem;
		font-weight: 600;
		color: #e2c47a;
	}
</style>
