using System;
using System.Collections;
using System.IO;
using Tessera;

namespace TesseraHub;

/// One release of a game or the engine on GitHub, with the file for this platform.
class Release
{
	public String tag = new .() ~ delete _;
	public String name = new .() ~ delete _;
	/// "2026-10-13".
	public String date = new .() ~ delete _;
	/// Marked as a pre-release on GitHub: shown as a beta.
	public bool beta;
	public String notes = new .() ~ delete _;
	public String assetUrl = new .() ~ delete _;
	public int64 assetSize;
	/// The release's SHA256SUMS file, if it has one.
	public String sumsUrl = new .() ~ delete _;

	public void CopyTo(Release other)
	{
		other.tag.Set(tag);
		other.name.Set(name);
		other.date.Set(date);
		other.beta = beta;
		other.notes.Set(notes);
		other.assetUrl.Set(assetUrl);
		other.assetSize = assetSize;
		other.sumsUrl.Set(sumsUrl);
	}
}

/// Asks GitHub for releases. Public repositories need no account; GitHub allows 60 questions an hour from one
/// address, so the Hub asks once when it starts and when Check for Updates is pressed.
static class Releases
{
	/// The newest release of item that has a file for this platform. With betas false, pre-releases are passed over.
	public static bool Latest(Catalog.Item item, bool betas, Release result, String error)
	{
		let text = scope String();
		if (!Http.GetText(scope $"https://api.github.com/repos/{item.repo}/releases?per_page=30", text, error))
			return false;
		let root = SaveNode.FromText(text);
		defer delete root;
		if (root == null || root.kind != .List)
		{
			// GitHub answers with an object when it refuses: {"message": "API rate limit exceeded ..."}.
			let message = root?["message"];
			error.Set(message != null && message.kind == .String ? message.text : "GitHub sent an answer the Hub does not understand.");
			return false;
		}
		for (let release in root.items)
		{
			if (Flag(release, "draft"))
				continue;
			let tag = Text(release, "tag_name");
			if (!item.tagPrefix.IsEmpty && !tag.StartsWith(item.tagPrefix))
				continue;
			let prerelease = Flag(release, "prerelease");
			if (prerelease && !betas)
				continue;
			let assets = release["assets"];
			if (assets == null)
				continue;
			bool found = false;
			result.sumsUrl.Clear();
			for (let asset in assets.items)
			{
				let name = Text(asset, "name");
				if (name == item.asset)
				{
					result.assetUrl.Set(Text(asset, "browser_download_url"));
					let size = asset["size"];
					result.assetSize = size != null ? size.AsInteger : 0;
					found = true;
				}
				else if (name.StartsWith("SHA256SUMS"))
					result.sumsUrl.Set(Text(asset, "browser_download_url"));
			}
			if (!found)
				continue;
			result.tag.Set(tag);
			result.name.Set(Text(release, "name"));
			if (result.name.IsEmpty)
				result.name.Set(tag);
			result.beta = prerelease;
			result.notes.Set(Text(release, "body"));
			let published = Text(release, "published_at");
			result.date.Set(published.Length >= 10 ? published.Substring(0, 10) : published);
			return true;
		}
		error.Set(betas ? "There is no release for this computer yet." : "There is no release for this computer yet that is not a beta.");
		return false;
	}

	/// Checks a downloaded file against the release's SHA256SUMS. True if it matches, or the release has no sums.
	public static bool Verify(Release release, StringView file, StringView assetName, String error)
	{
		if (release.sumsUrl.IsEmpty)
			return true;
		let sums = scope String();
		if (!Http.GetText(release.sumsUrl, sums, error))
			return false;
		let actual = scope String();
		if (!Task.HashFile(file, actual))
		{
			error.Set("Could not read the downloaded file.");
			return false;
		}
		for (var line in sums.Split('\n'))
		{
			line.Trim();
			// "<hash>  <name>" (or " *<name>" from a binary-mode sum).
			let space = line.IndexOf(' ');
			if (space < 0)
				continue;
			var name = line.Substring(space + 1);
			name.Trim();
			if (name.StartsWith('*'))
				name.RemoveFromStart(1);
			if (name != assetName)
				continue;
			let expected = scope String(line.Substring(0, space));
			expected.ToLower();
			if (expected == actual)
				return true;
			error.Set("The download is damaged (its checksum does not match). Try again.");
			return false;
		}
		// Sums for the other files only: nothing to check this one against.
		return true;
	}

	static StringView Text(SaveNode node, StringView key)
	{
		let value = node[key];
		return value != null && value.kind == .String ? value.text : "";
	}

	static bool Flag(SaveNode node, StringView key)
	{
		let value = node[key];
		return value != null && value.kind == .Bool && value.integer != 0;
	}
}
