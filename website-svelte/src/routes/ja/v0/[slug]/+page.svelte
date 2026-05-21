<script lang="ts">
	import DocsLayout from '$lib/components/DocsLayout.svelte';
	import { navV0Ja } from '$lib/nav';

	let { data } = $props();
</script>

<svelte:head>
	<title>{data.title || data.slug} — Amulet v0 ドキュメント（アーカイブ）</title>
</svelte:head>

<DocsLayout lang="ja" nav={navV0Ja} currentSlug={data.slug} headings={data.headings} title={data.title}>
	<div class="archived-banner">
		⚠️ これは Amulet v0.x（Zig 実装）のアーカイブドキュメントです。
		<a href="/ja/{data.slug}">現行 v1.0.0 ドキュメントを見る →</a>
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
