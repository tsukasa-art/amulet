<script lang="ts">
	import { page } from '$app/state';

	interface Props {
		lang: 'en' | 'ja';
		onMenuOpen?: () => void;
		hideMenu?: boolean;
	}

	let { lang, onMenuOpen, hideMenu = false }: Props = $props();

	const homeHref = $derived(lang === 'ja' ? '/ja' : '/');
	const otherLabel = $derived(lang === 'en' ? '日本語' : 'English');
	const langSwitchHref = $derived(
		lang === 'en'
			? '/ja' + (page.url.pathname === '/' ? '' : page.url.pathname)
			: page.url.pathname.replace(/^\/ja/, '') || '/'
	);
</script>

<header class="navbar" class:has-drawer={!hideMenu}>
	<div class="navbar-inner">
		<div class="navbar-left">
			{#if !hideMenu}
				<button class="menu-btn" onclick={onMenuOpen} aria-label="Open navigation">
					<svg width="20" height="20" viewBox="0 0 20 20" fill="none">
						<rect y="3" width="20" height="2" rx="1" fill="currentColor"/>
						<rect y="9" width="20" height="2" rx="1" fill="currentColor"/>
						<rect y="15" width="20" height="2" rx="1" fill="currentColor"/>
					</svg>
				</button>
			{/if}
			<a href={homeHref} class="site-title">
				<img src="/logo-icon.png" alt="Amulet" class="logo" />
				<span>Amulet</span>
			</a>
		</div>
		<div class="navbar-right">
			<a href={lang === 'ja' ? '/ja/concepts' : '/concepts'} class="docs-btn">{lang === 'ja' ? 'ドキュメント' : 'Docs'}</a>
			<a href={langSwitchHref} class="lang-btn">{otherLabel}</a>
			<a href="https://github.com/tsukasa-art/amulet" class="github-btn" target="_blank" rel="noopener">
				GitHub
				<svg width="12" height="12" viewBox="0 0 12 12" fill="none" style="margin-left:3px">
					<path d="M2 2h8M10 2v8M2 10l8-8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
				</svg>
			</a>
		</div>
	</div>
</header>

<style>
	.navbar {
		position: sticky;
		top: 0;
		z-index: 50;
		background: rgba(15, 23, 42, 0.92);
		border-bottom: 1px solid rgba(197, 160, 89, 0.2);
		backdrop-filter: blur(20px);
		-webkit-backdrop-filter: blur(20px);
	}

	.navbar-inner {
		display: flex;
		align-items: center;
		justify-content: space-between;
		height: 3.5rem;
		padding: 0 1rem;
		max-width: 100%;
	}

	.navbar-left {
		display: flex;
		align-items: center;
		gap: 0.75rem;
	}

	.menu-btn {
		display: none;
		background: none;
		border: none;
		color: #94a3b8;
		cursor: pointer;
		padding: 0.25rem;
		border-radius: 4px;
	}

	.menu-btn:hover {
		color: #e2e8f0;
	}

	.site-title {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		font-family: 'Outfit', sans-serif;
		font-weight: 900;
		font-size: 1.1rem;
		letter-spacing: 0.08em;
		color: #fcf9f2;
		text-decoration: none;
	}

	.logo {
		height: 1.75rem;
		width: auto;
	}

	.navbar-right {
		display: flex;
		align-items: center;
		gap: 0.75rem;
	}

	.docs-btn {
		font-size: 0.85rem;
		color: #e2e8f0;
		text-decoration: none;
		padding: 0.25rem 0.75rem;
		border-radius: 6px;
		border: 1px solid rgba(197,160,89,0.3);
		transition: border-color 0.15s, color 0.15s;
	}

	.docs-btn:hover {
		border-color: #c5a059;
		color: #c5a059;
	}

	.lang-btn {
		font-size: 0.85rem;
		color: #94a3b8;
		text-decoration: none;
		padding: 0.25rem 0.5rem;
		border-radius: 4px;
		transition: color 0.15s;
	}

	.lang-btn:hover {
		color: #c5a059;
	}

	.github-btn {
		display: flex;
		align-items: center;
		font-size: 0.85rem;
		color: #94a3b8;
		text-decoration: none;
		padding: 0.25rem 0.5rem;
		border-radius: 4px;
		transition: color 0.15s;
	}

	.github-btn:hover {
		color: #e2e8f0;
	}

	@media (max-width: 768px) {
		.menu-btn {
			display: flex;
		}

		/* ドロワーあり（ドキュメントページ）: 全リンクを隠す（ドロワー内にある） */
		.navbar.has-drawer .docs-btn,
		.navbar.has-drawer .lang-btn,
		.navbar.has-drawer .github-btn {
			display: none;
		}

		/* ドロワーなし（ホームページ）: 言語切替だけ残す */
		.navbar:not(.has-drawer) .docs-btn,
		.navbar:not(.has-drawer) .github-btn {
			display: none;
		}
	}
</style>
