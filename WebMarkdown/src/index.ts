import { Crepe, CrepeFeature } from '@milkdown/crepe';
import '@milkdown/crepe/theme/common/style.css';
import '@milkdown/crepe/theme/frame.css';

let crepe: Crepe | undefined;
let isExternalUpdate = false;
let debounceTimer: ReturnType<typeof setTimeout> | undefined;

async function initEditor(content: string): Promise<void> {
	const root = document.getElementById('editor');
	if (!root) return;

	crepe = new Crepe({
		root,
		defaultValue: content,
		features: {
			[CrepeFeature.BlockEdit]: false,
			[CrepeFeature.TopBar]: false,
			[CrepeFeature.Toolbar]: false,
			[CrepeFeature.Placeholder]: false,
		},
	});

	crepe.on((listener) => {
		return listener.markdownUpdated((_ctx, markdown, prevMarkdown) => {
			if (isExternalUpdate || markdown === prevMarkdown) return;
			if (debounceTimer) clearTimeout(debounceTimer);
			debounceTimer = setTimeout(() => {
				(window as any).webkit?.messageHandlers?.markdownHandler?.postMessage({
					type: 'contentChanged',
					content: markdown,
				});
			}, 300);
		});
	});

	await crepe.create();
}

(window as any).markdownOpen = async (content: string) => {
	if (crepe) {
		await crepe.destroy();
		crepe = undefined;
		const root = document.getElementById('editor');
		if (root) root.innerHTML = '';
	}
	await initEditor(content);
};

(window as any).markdownGetContent = () => {
	return crepe?.getMarkdown() || '';
};

// Signal ready
(window as any).webkit?.messageHandlers?.markdownHandler?.postMessage({
	type: 'ready',
});
