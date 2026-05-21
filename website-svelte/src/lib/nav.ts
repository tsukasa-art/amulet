export interface NavItem {
	slug: string;
	label: string;
}

export interface NavGroup {
	label: string;
	items: NavItem[];
}

export const navEn: NavGroup[] = [
	{
		label: 'Fundamentals',
		items: [
			{ slug: 'concepts', label: 'Concepts & Fundamentals' },
			{ slug: 'getting-started', label: 'Installation & Setup' },
			{ slug: 'usage', label: 'CLI Usage Reference' },
			{ slug: 'security', label: 'Security Reference' }
		]
	},
	{
		label: 'Deployment',
		items: [
			{ slug: 'deployment', label: 'Deployment, Migration & Docker' },
			{ slug: 'deploy-ubuntu', label: 'Ubuntu Production (systemd)' },
			{ slug: 'deploy-rootless-systemd', label: 'Rootless Deployment' }
		]
	},
	{
		label: 'Maintenance',
		items: [
			{ slug: 'troubleshooting', label: 'Troubleshooting' },
			{ slug: 'migration-away', label: 'Stopping Use of Amulet' }
		]
	}
];

export const navV0En: NavGroup[] = [
	{
		label: 'v0.x (Archived — Zig)',
		items: [
			{ slug: 'concepts', label: 'Concepts & Fundamentals' },
			{ slug: 'getting-started', label: 'Installation & Setup' },
			{ slug: 'usage', label: 'CLI Usage Reference' },
			{ slug: 'security', label: 'Security Reference' },
			{ slug: 'deployment', label: 'Deployment, Migration & Docker' },
			{ slug: 'deploy-ubuntu', label: 'Ubuntu Production (systemd)' },
			{ slug: 'deploy-rootless-systemd', label: 'Rootless Deployment' },
			{ slug: 'troubleshooting', label: 'Troubleshooting' },
			{ slug: 'migration-away', label: 'Stopping Use of Amulet' }
		]
	}
];

export const navV0Ja: NavGroup[] = [
	{
		label: 'v0.x（アーカイブ — Zig）',
		items: [
			{ slug: 'concepts', label: '概念と基礎知識' },
			{ slug: 'getting-started', label: 'インストールと初期設定' },
			{ slug: 'usage', label: 'CLI使用リファレンス' },
			{ slug: 'security', label: 'セキュリティリファレンス' },
			{ slug: 'deployment', label: 'デプロイ、移行、およびDocker Compose' },
			{ slug: 'deploy-ubuntu', label: 'Ubuntu本番環境へのデプロイ (systemd)' },
			{ slug: 'deploy-rootless-systemd', label: 'ルートレスデプロイメント' },
			{ slug: 'troubleshooting', label: 'トラブルシューティング' },
			{ slug: 'migration-away', label: 'Amulet の使用を中止する' }
		]
	}
];

export const navJa: NavGroup[] = [
	{
		label: '基礎知識',
		items: [
			{ slug: 'concepts', label: '概念と基礎知識' },
			{ slug: 'getting-started', label: 'インストールと初期設定' },
			{ slug: 'usage', label: 'CLI使用リファレンス' },
			{ slug: 'security', label: 'セキュリティリファレンス' }
		]
	},
	{
		label: 'デプロイ',
		items: [
			{ slug: 'deployment', label: 'デプロイ、移行、およびDocker Compose' },
			{ slug: 'deploy-ubuntu', label: 'Ubuntu本番環境へのデプロイ (systemd)' },
			{ slug: 'deploy-rootless-systemd', label: 'ルートレスデプロイメント' }
		]
	},
	{
		label: '保守・その他',
		items: [
			{ slug: 'troubleshooting', label: 'トラブルシューティング' },
			{ slug: 'migration-away', label: 'Amulet の使用を中止する' }
		]
	}
];
