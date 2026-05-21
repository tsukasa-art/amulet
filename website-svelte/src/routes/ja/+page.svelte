<script lang="ts">
	import Navbar from '$lib/components/Navbar.svelte';

	let tabInstall = $state('mac');
	let tabSeal = $state('mac');
	let tabUse = $state('mac');
</script>

<svelte:head>
	<title>Amulet — ハードウェア紐付け型、痕跡を残さない秘密情報マネージャー</title>
	<meta name="description" content="Amuletは、個人開発者やAI支援開発のために設計された、ハードウェア紐付け型のシークレットマネージャーです。" />
</svelte:head>

<div class="page">
	<Navbar lang="ja" hideMenu />

	<section class="hero">
		<div class="hero-content">
			<div class="logo-wrap">
				<img src="/logo-icon.png" alt="Amulet" class="hero-logo" />
				<div class="logo-glow"></div>
			</div>
			<h1 class="hero-title">
				<span>AIや不注意による</span>
				<span>秘密情報の流出を防ぐ</span>
			</h1>
			<p class="hero-sub">
				Amuletは、個人開発者やAI支援開発のために設計された、ハードウェア紐付け型のシークレットマネージャーです。
				もう .env ファイルは必要ありません。誤ったコミットも、AIによる盗み見も構造的に防ぎます。
			</p>
			<div class="hero-actions">
				<a href="/ja/concepts" class="btn-primary">使ってみる</a>
				<a href="https://github.com/tsukasa-art/amulet" class="btn-outline" target="_blank" rel="noopener">GitHubを見る</a>
			</div>
		</div>
	</section>

	<section class="steps container">
		<h2 class="section-title">導入はわずか3ステップ</h2>
		<div class="stepper">
			<!-- Step 1 -->
			<div class="step-card">
				<div class="step-head">
					<span class="step-num">01</span>
					<h3>Install <small>（インストール）</small></h3>
				</div>
				<div class="step-body">
					<p>お使いの環境に合わせて、以下のコマンドでCLIをインストールします。</p>
					<div class="tab-terminal">
						<div class="tab-header">
							{#each [['mac','macOS'],['win','Windows'],['linux','Linux / Other']] as [id, label]}
								<button class="tab-btn" class:active={tabInstall===id} onclick={() => tabInstall = id}>{label}</button>
							{/each}
						</div>
						{#if tabInstall === 'mac'}
							<div class="mt-body"><span class="mt-prompt">$</span><code>brew tap tsukasa-art/amulet && brew install amulet</code></div>
						{:else if tabInstall === 'win'}
							<div class="mt-body"><span class="mt-prompt">PS&gt;</span><code>scoop bucket add amulet https://github.com/tsukasa-art/scoop-amulet.git && scoop install amulet</code></div>
						{:else}
							<div class="mt-body"><span class="mt-prompt">$</span><code>curl -fsSL https://amulet.pages.dev/install.sh | sh</code></div>
						{/if}
					</div>
				</div>
			</div>

			<!-- Step 2 -->
			<div class="step-card">
				<div class="step-head">
					<span class="step-num">02</span>
					<h3>Seal <small>（暗号化して保存）</small></h3>
				</div>
				<div class="step-body">
					<p>秘密情報を暗号化し、あなたのマシンに紐付けます。</p>
					<div class="tab-terminal">
						<div class="tab-header">
							{#each [['mac','macOS / Linux'],['win','Windows (PS)']] as [id, label]}
								<button class="tab-btn" class:active={tabSeal===id} onclick={() => tabSeal = id}>{label}</button>
							{/each}
						</div>
						{#if tabSeal === 'mac'}
							<div class="mt-body"><span class="mt-prompt">$</span><code>echo -n "secret" | amulet seal OPENAI_KEY</code></div>
						{:else}
							<div class="mt-body"><span class="mt-prompt">PS&gt;</span><code>"secret" | amulet seal OPENAI_KEY</code></div>
						{/if}
					</div>
				</div>
			</div>

			<!-- Step 3 -->
			<div class="step-card">
				<div class="step-head">
					<span class="step-num">03</span>
					<h3>Use <small>（安全に取り出す）</small></h3>
				</div>
				<div class="step-body">
					<p>SDKまたはCLIでシークレットを取り出します。ディスクに痕跡を残しません。</p>
					<div class="tab-terminal">
						<div class="tab-header">
							{#each [['mac','macOS / Linux'],['win','Windows']] as [id, label]}
								<button class="tab-btn" class:active={tabUse===id} onclick={() => tabUse = id}>{label}</button>
							{/each}
						</div>
						{#if tabUse === 'mac'}
							<div class="mt-body"><span class="mt-prompt">$</span><code>amulet unseal OPENAI_KEY</code></div>
						{:else}
							<div class="mt-body"><span class="mt-prompt">PS&gt;</span><code>amulet unseal OPENAI_KEY</code></div>
						{/if}
					</div>
				</div>
			</div>
		</div>
	</section>

	<section class="features container">
		<div class="feature-grid">
			<div class="feature-card">
				<div class="feature-icon">
					<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="11" x="3" y="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>
				</div>
				<h3>ハードウェア紐付け</h3>
				<p>シークレットはOSのマシン識別子に紐付けて暗号化されます。封印したマシン上でのみ動作します。</p>
			</div>
			<div class="feature-card">
				<div class="feature-icon">
					<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><circle cx="12" cy="10" r="3"/><path d="M7 20.662V19a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v1.662"/></svg>
				</div>
				<h3>AI対応設計</h3>
				<p>標準入力（stdin）から読み込むことで、AIコーディングアシスタントがコマンド引数の秘密情報を見ることを構造的に防ぎます。</p>
			</div>
			<div class="feature-card">
				<div class="feature-icon">
					<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m2 7 4.41-4.41A2 2 0 0 1 7.83 2h8.34a2 2 0 0 1 1.42.59L22 7"/><path d="M4 12c-1.1 0-2-.9-2-2V7c0-1.1.9-2 2-2h16c1.1 0 2 .9 2 2v3c0 1.1-.9 2-2 2"/><path d="M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7"/><path d="M9 17h6"/></svg>
				</div>
				<h3>ゼロトレース</h3>
				<p>サーバー不要。完全ローカルで動作。最大限のプライバシーとオフライン利用を確保します。</p>
			</div>
		</div>
	</section>

	<section class="terminal-preview container">
		<div class="terminal">
			<div class="terminal-header">
				<span class="dot red"></span>
				<span class="dot yellow"></span>
				<span class="dot green"></span>
				<span class="terminal-title">bash</span>
			</div>
			<div class="terminal-body">
				<div class="t-line"><span class="t-comment"># シークレットを保存する</span></div>
				<div class="t-line"><span class="t-prompt">$</span> <span class="t-cmd">echo -n "sk-..." | amulet seal OPENAI_KEY --file secrets.vault</span></div>
				<div class="t-line"><span class="t-out">Passphrase: ***********</span></div>
				<div class="t-line"></div>
				<div class="t-line"><span class="t-comment"># 取り出す（このマシンでのみ動作）</span></div>
				<div class="t-line"><span class="t-prompt">$</span> <span class="t-cmd">amulet unseal OPENAI_KEY --file secrets.vault</span></div>
			</div>
		</div>
	</section>
</div>

<style>
	.page {
		min-height: 100vh;
		background-image: radial-gradient(circle at 100% 150%,
			transparent 24%, rgba(197, 160, 89, 0.05) 25%, rgba(197, 160, 89, 0.05) 28%, transparent 29%,
			transparent 36%, rgba(197, 160, 89, 0.05) 36%, rgba(197, 160, 89, 0.05) 40%, transparent 41%);
		background-size: 60px 60px;
		background-attachment: fixed;
	}

	.container { max-width: 900px; margin: 0 auto; padding: 0 1.5rem; }

	.hero { padding: 7rem 1.5rem 5rem; text-align: center; }
	.hero-content { max-width: 860px; margin: 0 auto; }

	.logo-wrap { position: relative; display: inline-block; margin-bottom: 2.5rem; }
	.hero-logo { width: 160px; height: 160px; object-fit: contain; border-radius: 28px; position: relative; z-index: 2; box-shadow: 0 20px 50px rgba(0,0,0,0.6); border: 1px solid rgba(197,160,89,0.2); }
	.logo-glow { position: absolute; top: 50%; left: 50%; transform: translate(-50%,-50%); width: 120%; height: 120%; background: radial-gradient(circle, rgba(197,160,89,1) 0%, transparent 70%); opacity: 0.12; filter: blur(40px); z-index: 1; }

	.hero-title { font-family: 'Outfit', sans-serif; font-size: clamp(2.2rem, 6vw, 3.5rem); font-weight: 900; line-height: 1.2; margin: 0 0 1.75rem; display: flex; flex-direction: column; gap: 0.2rem; background: linear-gradient(to bottom, #fcf9f2, #cbd5e1); -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text; }
	.hero-sub { font-size: 1.1rem; color: #94a3b8; max-width: 680px; margin: 0 auto 2.5rem; line-height: 1.7; }
	.hero-actions { display: flex; gap: 1rem; justify-content: center; flex-wrap: wrap; }

	.btn-primary { display: inline-block; background: linear-gradient(135deg, #c5a059, #d4b07a); color: #0f172a; font-weight: 700; padding: 0.75rem 2rem; border-radius: 10px; text-decoration: none; font-size: 1rem; transition: opacity 0.15s; }
	.btn-primary:hover { opacity: 0.85; }
	.btn-outline { display: inline-flex; align-items: center; gap: 0.4rem; background: transparent; color: #e2e8f0; font-weight: 600; padding: 0.75rem 2rem; border-radius: 10px; text-decoration: none; font-size: 1rem; border: 1px solid rgba(197,160,89,0.3); transition: border-color 0.15s, color 0.15s; }
	.btn-outline:hover { border-color: #c5a059; color: #c5a059; }

	.steps { margin: 8rem auto; }
	.section-title { text-align: center; font-family: 'Outfit', sans-serif; font-size: 2rem; font-weight: 700; color: #fcf9f2; margin: 0 0 3.5rem; }
	.stepper { display: flex; flex-direction: column; gap: 2rem; }

	.step-card { background: rgba(255,255,255,0.03); border: 1px solid rgba(197,160,89,0.15); border-radius: 20px; overflow: hidden; transition: border-color 0.2s; }
	.step-card:hover { border-color: rgba(197,160,89,0.3); }
	.step-head { padding: 1.5rem 2rem; background: rgba(255,255,255,0.02); border-bottom: 1px solid rgba(255,255,255,0.05); display: flex; align-items: center; gap: 1.25rem; }
	.step-num { font-family: 'Outfit', sans-serif; font-size: 1.1rem; font-weight: 900; color: #c5a059; background: rgba(197,160,89,0.1); padding: 0.4rem 0.9rem; border-radius: 10px; border: 1px solid rgba(197,160,89,0.2); }
	.step-head h3 { font-size: 1.4rem; margin: 0; color: #fcf9f2; }
	.step-head h3 small { font-size: 0.85rem; color: #64748b; font-weight: 400; margin-left: 0.4rem; }
	.step-body { padding: 1.75rem 2rem; display: flex; flex-direction: column; gap: 1.25rem; }
	.step-body p { color: #94a3b8; margin: 0; font-size: 1rem; }

	.tab-terminal { background: #000; border-radius: 12px; overflow: hidden; border: 1px solid rgba(197,160,89,0.2); }
	.tab-header { background: #0d0d0d; display: flex; border-bottom: 1px solid #1a1a1a; }
	.tab-btn { background: transparent; border: none; padding: 0.7rem 1.25rem; color: #64748b; font-family: 'Outfit', sans-serif; font-size: 0.875rem; font-weight: 600; cursor: pointer; border-bottom: 2px solid transparent; transition: color 0.15s, border-color 0.15s; white-space: nowrap; min-height: 44px; }
	.tab-btn.active { color: #c5a059; border-bottom-color: #c5a059; }
	.mt-body { padding: 1.25rem 1.5rem; font-family: 'Fira Code', monospace; font-size: 0.9rem; color: #c5a059; display: flex; gap: 0.75rem; overflow-x: auto; }
	.mt-prompt { color: rgba(197,160,89,0.6); flex-shrink: 0; }
	.mt-body code { color: #e2e8f0; background: none; border: none; padding: 0; font-family: inherit; font-size: inherit; }

	.features { padding: 4rem 0 6rem; }
	.feature-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1.5rem; }
	.feature-card { padding: 2rem; background: rgba(255,255,255,0.02); border: 1px solid rgba(197,160,89,0.12); border-radius: 16px; }
	.feature-icon { color: #c5a059; margin-bottom: 1rem; }
	.feature-card h3 { font-size: 1.1rem; font-weight: 700; color: #e2e8f0; margin: 0 0 0.5rem; }
	.feature-card p { font-size: 0.9rem; color: #64748b; line-height: 1.6; margin: 0; }

	.terminal-preview { margin-bottom: 8rem; }
	.terminal { background: #000; border-radius: 14px; overflow: hidden; border: 1px solid rgba(197,160,89,0.15); box-shadow: 0 30px 60px rgba(0,0,0,0.5); }
	.terminal-header { background: #111; padding: 0.7rem 1rem; display: flex; align-items: center; gap: 0.5rem; }
	.dot { width: 12px; height: 12px; border-radius: 50%; display: inline-block; }
	.dot.red { background: #ff5f56; } .dot.yellow { background: #ffbd2e; } .dot.green { background: #27c93f; }
	.terminal-title { font-family: 'Fira Code', monospace; font-size: 0.75rem; color: #475569; margin-left: 0.5rem; }
	.terminal-body { padding: 2rem; font-family: 'Fira Code', monospace; font-size: 0.9rem; line-height: 1.8; overflow-x: auto; }
	.t-line { display: flex; gap: 0.75rem; }
	.t-prompt { color: #c5a059; flex-shrink: 0; } .t-cmd { color: #e2e8f0; } .t-comment { color: #475569; } .t-out { color: #64748b; }

	@media (max-width: 768px) {
		.hero { padding: 5rem 1.25rem 3rem; }
		.feature-grid { grid-template-columns: 1fr; }
		.step-head { padding: 1.25rem; } .step-body { padding: 1.25rem; }
		.terminal-body { padding: 1.25rem; font-size: 0.8rem; }
		.steps { margin: 5rem auto; }
	}
</style>
