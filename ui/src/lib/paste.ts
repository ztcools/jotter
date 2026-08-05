/** Reads every image from a clipboard paste event as data URLs.
 *
 * Kept here rather than inline in the two components that handle paste, so the
 * FileReader wiring and the early-return-on-first-image bug are fixed in one
 * place and the two sites stay in sync by construction. */
export async function readImagesFromClipboard(
	event: ClipboardEvent,
): Promise<string[]> {
	const dt = event.clipboardData;
	if (!dt) return [];
	const results: string[] = [];
	for (let i = 0; i < dt.items.length; i++) {
		const item = dt.items[i];
		if (!item || !item.type.startsWith('image/')) continue;
		event.preventDefault();
		const blob = item.getAsFile();
		if (!blob) continue;
		const dataUrl = await new Promise<string>((resolve) => {
			const reader = new FileReader();
			reader.onload = () => resolve(reader.result as string);
			reader.readAsDataURL(blob);
		});
		results.push(dataUrl);
	}
	return results;
}
