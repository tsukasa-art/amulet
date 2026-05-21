<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import Navbar from './Navbar.svelte';
	import Sidebar from './Sidebar.svelte';
	import type { NavGroup } from '$lib/nav';
	import type { Heading } from '$lib/utils/markdown';
	interface Props {
		lang: 'en' | 'ja';
		nav: NavGroup[];
		currentSlug: string;
		headings: Heading[];
		title?: string;
		children: import('svelte').Snippet;
	}

	let { lang, nav, currentSlug, headings, title, children }: Props = $props();

	let mobileOpen = $state(false);
	const langSwitchHref = $derived(
		lang === 'en'
			? '/ja' + (page.url.pathname === '/' ? '' : page.url.pathname)
			: page.url.pathname.replace(/^\/ja/, '') || '/'
	);
	const tocHeadings = $derived(headings.filter(h => h.level === 2));

	function scrollToHeading(e: MouseEvent, id: string) {
		e.preventDefault();
		const el = document.getElementById(id);
		if (!el) return;
		history.pushState(null, '', `#${id}`);
		el.scrollIntoView({ behavior: 'smooth', block: 'start' });
		el.classList.remove('heading-flash');
		void el.offsetHeight; // force reflow to re-trigger animation
		el.classList.add('heading-flash');
		setTimeout(() => el.classList.remove('heading-flash'), 1400);
	}

	// Scroll-spy: track the last heading whose top is above the scroll threshold
	let activeId = $state<string | null>(null);

	$effect(() => {
		if (tocHeadings.length === 0) return;
		activeId = tocHeadings[0].id;

		function onScroll() {
			const nearBottom =
				window.scrollY + window.innerHeight >= document.body.scrollHeight - 10;
			if (nearBottom) {
				activeId = tocHeadings[tocHeadings.length - 1].id;
				return;
			}
			const threshold = window.scrollY + 120;
			let current = tocHeadings[0].id;
			for (const h of tocHeadings) {
				const el = document.getElementById(h.id);
				if (el && el.offsetTop <= threshold) current = h.id;
			}
			activeId = current;
		}

		window.addEventListener('scroll', onScroll, { passive: true });
		onScroll();

		return () => window.removeEventListener('scroll', onScroll);
	});
</script>

<div class="page-wrapper">
	<Navbar {lang} onMenuOpen={() => mobileOpen = true} />

	<!-- Mobile overlay -->
	{#if mobileOpen}
		<div
			class="overlay"
			role="button"
			tabindex="-1"
			aria-label="Close menu"
			onclick={() => mobileOpen = false}
			onkeydown={(e) => e.key === 'Escape' && (mobileOpen = false)}
		></div>
	{/if}

	<!-- Mobile sidebar drawer -->
	<div class="mobile-sidebar" class:open={mobileOpen}>
		<div class="mobile-sidebar-header">
			<span class="mobile-site-title">Amulet</span>
			<button class="close-btn" onclick={() => mobileOpen = false} aria-label="Close">
				<svg width="20" height="20" viewBox="0 0 20 20" fill="none">
					<path d="M4 4l12 12M16 4L4 16" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
				</svg>
			</button>
		</div>
		<Sidebar {nav} {lang} {currentSlug} onNavigate={() => mobileOpen = false} />
		<div class="mobile-footer-links">
			{#if lang === 'ja'}
				<a href="/ja/concepts" class="mobile-footer-link" onclick={() => mobileOpen = false}>ドキュメント</a>
				<a href={langSwitchHref} class="mobile-footer-link" onclick={() => mobileOpen = false}>English</a>
			{:else}
				<a href="/concepts" class="mobile-footer-link" onclick={() => mobileOpen = false}>Docs</a>
				<a href={langSwitchHref} class="mobile-footer-link" onclick={() => mobileOpen = false}>日本語</a>
			{/if}
			<a href="https://github.com/tsukasa-art/amulet" class="mobile-footer-link" target="_blank" rel="noopener">GitHub ↗</a>
		</div>
	</div>

	<div class="docs-body">
		<!-- Desktop sidebar -->
		<aside class="desktop-sidebar">
			<Sidebar {nav} {lang} {currentSlug} />
		</aside>

		<!-- Main content -->
		<main class="docs-main">
			<article class="prose">
				{#if title}
					<h1 class="page-title">{title}</h1>
				{/if}
				{@render children()}
			</article>

			<!-- Prev/Next navigation is handled per-page -->
		</main>

		<!-- TOC -->
		{#if tocHeadings.length > 0}
			<aside class="toc-sidebar">
				<div class="toc-inner">
					<p class="toc-title">{lang === 'ja' ? 'このページの内容' : 'On this page'}</p>
					<ul>
						{#each tocHeadings as h}
							<li>
								<a href="#{h.id}" class="toc-link" class:active={activeId === h.id} onclick={(e) => scrollToHeading(e, h.id)}>{h.text}</a>
							</li>
						{/each}
					</ul>
				</div>
			</aside>
		{/if}
	</div>
</div>

<style>
	.page-wrapper {
		min-height: 100vh;
		background-image: radial-gradient(circle at 100% 150%,
			transparent 24%, rgba(197, 160, 89, 0.05) 25%, rgba(197, 160, 89, 0.05) 28%, transparent 29%,
			transparent 36%, rgba(197, 160, 89, 0.05) 36%, rgba(197, 160, 89, 0.05) 40%, transparent 41%);
		background-size: 60px 60px;
		background-attachment: fixed;
	}

	.docs-body {
		display: grid;
		grid-template-columns: 16rem 1fr 14rem;
		max-width: 1400px;
		margin: 0 auto;
		min-height: calc(100vh - 3.5rem);
	}

	.desktop-sidebar {
		border-right: 1px solid rgba(197, 160, 89, 0.12);
		position: sticky;
		top: 3.5rem;
		height: calc(100vh - 3.5rem);
		overflow-y: auto;
	}

	.docs-main {
		padding: 2.5rem 3rem;
		padding-bottom: 60vh;
		min-width: 0;
	}

	.prose {
		max-width: 800px;
	}

	.page-title {
		font-family: 'Outfit', sans-serif;
		font-size: 2rem;
		font-weight: 700;
		color: #c5a059;
		margin: 0 0 2rem;
		padding-bottom: 0.75rem;
		border-bottom: 1px solid rgba(197,160,89,0.2);
		line-height: 1.3;
	}

	.toc-sidebar {
		border-left: 1px solid rgba(197, 160, 89, 0.12);
		position: sticky;
		top: 3.5rem;
		height: calc(100vh - 3.5rem);
		overflow-y: auto;
	}

	.toc-inner {
		padding: 1.5rem 1rem;
	}

	.toc-title {
		font-size: 0.7rem;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.08em;
		color: #475569;
		margin-bottom: 0.75rem;
	}

	.toc-inner ul {
		list-style: none;
		padding: 0;
		margin: 0;
	}

	.toc-link {
		display: block;
		font-size: 0.82rem;
		color: #64748b;
		text-decoration: none;
		padding: 0.25rem 0;
		line-height: 1.5;
		transition: color 0.15s;
	}

	.toc-link:hover {
		color: #c5a059;
	}

	.toc-link.active {
		color: #c5a059;
		font-weight: 600;
	}

	/* Mobile */
	.overlay {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.6);
		z-index: 40;
	}

	.mobile-sidebar {
		position: fixed;
		top: 0;
		left: 0;
		width: 280px;
		height: 100vh;
		background: #111827;
		border-right: 1px solid rgba(197, 160, 89, 0.2);
		z-index: 50;
		transform: translateX(-100%);
		transition: transform 0.25s ease;
		overflow-y: auto;
	}

	.mobile-sidebar.open {
		transform: translateX(0);
	}

	.mobile-sidebar-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 0 1rem;
		height: 3.5rem;
		border-bottom: 1px solid rgba(197, 160, 89, 0.15);
	}

	.mobile-site-title {
		font-family: 'Outfit', sans-serif;
		font-weight: 900;
		letter-spacing: 0.08em;
		color: #fcf9f2;
	}

	.close-btn {
		background: none;
		border: none;
		color: #94a3b8;
		cursor: pointer;
		padding: 0.25rem;
		border-radius: 4px;
		min-width: 44px;
		min-height: 44px;
		display: flex;
		align-items: center;
		justify-content: center;
	}

	.close-btn:hover {
		color: #e2e8f0;
	}

	.mobile-footer-links {
		border-top: 1px solid rgba(197, 160, 89, 0.15);
		padding: 1rem;
		display: flex;
		flex-direction: column;
		gap: 0.25rem;
	}

	.mobile-footer-link {
		display: block;
		padding: 0.6rem 0.75rem;
		font-size: 0.9rem;
		color: #64748b;
		text-decoration: none;
		border-radius: 6px;
		transition: color 0.15s, background 0.15s;
	}

	.mobile-footer-link:hover {
		color: #e2e8f0;
		background: rgba(197, 160, 89, 0.06);
	}

	@media (max-width: 1100px) {
		.docs-body {
			grid-template-columns: 16rem 1fr;
		}

		.toc-sidebar {
			display: none;
		}
	}

	@media (max-width: 768px) {
		.docs-body {
			grid-template-columns: 1fr;
		}

		.desktop-sidebar {
			display: none;
		}

		.docs-main {
			padding: 1.5rem 1.25rem;
		}
	}
</style>
