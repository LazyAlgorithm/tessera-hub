using System;
using System.Collections;
using Tessera;

namespace TesseraHub;

/// What the Hub offers: games and the engine (Items), and the tools some of them need (Dependencies). Read from
/// catalog.json, which lives in the Hub's repository and is fetched when the Hub starts (a copy is built in, for
/// when there is no connection). A game or tool is added by editing that file; no new Hub is needed.
class Catalog
{
	public class Item
	{
		public String id = new .() ~ delete _;
		/// "game" or "engine".
		public String kind = new .() ~ delete _;
		public String name = new .() ~ delete _;
		public String summary = new .() ~ delete _;
		/// GitHub repository the releases come from: "owner/name".
		public String repo = new .() ~ delete _;
		/// Only releases whose tag starts with this (empty: any).
		public String tagPrefix = new .() ~ delete _;
		/// The release file for this platform, and the program in it to start (relative to the unpacked folder).
		public String asset = new .() ~ delete _;
		public String run = new .() ~ delete _;
		/// Picture for its page: an image in the Hub's own assets (UI/ringfall.png), or a web address.
		public String banner = new .() ~ delete _;
		/// Small square picture for the list.
		public String icon = new .() ~ delete _;
		/// Ids of dependencies that must be present before it is installed.
		public List<String> requires = new .() ~ DeleteContainerAndItems!(_);
		/// Still in beta: shown with a BETA badge.
		public bool beta;
		/// Accent colour for its page ("#e0503a"), and how to show it in the list.
		public String accent = new .() ~ delete _;
		/// True when there is a build for this platform.
		public bool Available => !asset.IsEmpty;
	}

	/// One check that a tool is present. Any of a dependency's checks passing means it is found.
	public class Check
	{
		public enum Kind { File, Program, Env, Command, Libraries, VisualStudio, BeefLibraries, All }
		public Kind kind;
		public String value = new .() ~ delete _;
		public List<String> values = new .() ~ DeleteContainerAndItems!(_);
		/// For All: every one of these must pass.
		public List<Check> parts = new .() ~ DeleteContainerAndItems!(_);
	}

	/// One step of installing a tool.
	public class Step
	{
		public enum Kind { Download, Run, RunAdmin, ConfigureMicrosoft, Packages, Write, Delete }
		public Kind kind;
		/// Download: the URL. Run: the command. Write and Delete: the path.
		public String value = new .() ~ delete _;
		/// Download: where to unpack it (empty: just download into the tools folder). Write: the text.
		public String extra = new .() ~ delete _;
		/// Packages: package manager -> package list.
		public Dictionary<String, String> packages = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	}

	public class Dependency
	{
		public String id = new .() ~ delete _;
		public String name = new .() ~ delete _;
		public String summary = new .() ~ delete _;
		public String size = new .() ~ delete _;
		/// Needed on this platform at all (a dependency can be for one platform only).
		public bool applies = true;
		public String licenceName = new .() ~ delete _;
		public String licenceUrl = new .() ~ delete _;
		public List<Check> found = new .() ~ DeleteContainerAndItems!(_);
		public List<Step> install = new .() ~ DeleteContainerAndItems!(_);
		/// Installed along with this one even if found elsewhere (what its install steps write into).
		public List<String> alsoInstall = new .() ~ DeleteContainerAndItems!(_);
		public bool NeedsLicence => !licenceName.IsEmpty;
	}

	public List<Item> Items = new .() ~ DeleteContainerAndItems!(_);
	public List<Dependency> Dependencies = new .() ~ DeleteContainerAndItems!(_);

	/// The platform key used in the catalog: "windows", "linux" or "macos".
	public static StringView Platform
	{
		get
		{
#if BF_PLATFORM_WINDOWS
			return "windows";
#elif BF_PLATFORM_MACOS
			return "macos";
#else
			return "linux";
#endif
		}
	}

	public Item FindItem(StringView id)
	{
		for (let item in Items)
			if (item.id == id)
				return item;
		return null;
	}

	public Dependency FindDependency(StringView id)
	{
		for (let dependency in Dependencies)
			if (dependency.id == id)
				return dependency;
		return null;
	}

	/// A text value, or this platform's entry of a per-platform object ({"windows": ..., "linux": ...}).
	static void ForPlatform(SaveNode node, String output)
	{
		if (node == null)
			return;
		if (node.kind == .String)
			output.Set(node.text);
		else if (node.kind == .Object)
		{
			let mine = node[Platform];
			if (mine != null && mine.kind == .String)
				output.Set(mine.text);
		}
	}

	static void Text(SaveNode node, StringView key, String output)
	{
		let value = node[key];
		if (value != null && value.kind == .String)
			output.Set(value.text);
	}

	/// Reads a catalog. False, with error, if the text is not one.
	public bool Parse(StringView json, String error)
	{
		let root = SaveNode.FromText(json);
		defer delete root;
		if (root == null || root.kind != .Object)
		{
			error.Set("The catalog is not valid JSON.");
			return false;
		}
		ClearAndDeleteItems!(Items);
		ClearAndDeleteItems!(Dependencies);
		let items = root["items"];
		for (int i < (items != null ? items.Count : 0))
		{
			let node = items.items[i];
			let item = new Item();
			Text(node, "id", item.id);
			Text(node, "kind", item.kind);
			Text(node, "name", item.name);
			Text(node, "summary", item.summary);
			Text(node, "repo", item.repo);
			Text(node, "tagPrefix", item.tagPrefix);
			Text(node, "banner", item.banner);
			Text(node, "accent", item.accent);
			Text(node, "icon", item.icon);
			let beta = node["beta"];
			item.beta = beta != null && beta.kind == .Bool && beta.integer != 0;
			ForPlatform(node["assets"], item.asset);
			ForPlatform(node["run"], item.run);
			let requires = node["requires"];
			for (int r < (requires != null ? requires.Count : 0))
				if (requires.items[r].kind == .String)
					item.requires.Add(new .(requires.items[r].text));
			if (item.id.IsEmpty || item.repo.IsEmpty)
			{
				delete item;
				continue;
			}
			Items.Add(item);
		}
		let dependencies = root["dependencies"];
		for (int i < (dependencies != null ? dependencies.Count : 0))
		{
			let node = dependencies.items[i];
			let dependency = new Dependency();
			Text(node, "id", dependency.id);
			Text(node, "name", dependency.name);
			Text(node, "summary", dependency.summary);
			Text(node, "size", dependency.size);
			let platforms = node["platforms"];
			if (platforms != null && platforms.kind == .List)
			{
				dependency.applies = false;
				for (let p in platforms.items)
					dependency.applies |= p.kind == .String && p.text == Platform;
			}
			let licence = node["licence"];
			if (licence != null)
			{
				Text(licence, "name", dependency.licenceName);
				Text(licence, "url", dependency.licenceUrl);
			}
			let found = node["found"];
			for (int c < (found != null ? found.Count : 0))
			{
				let check = ParseCheck(found.items[c]);
				if (check != null)
					dependency.found.Add(check);
			}
			let installs = node["install"];
			let install = installs != null ? installs[Platform] : null;
			for (int s < (install != null ? install.Count : 0))
			{
				let step = ParseStep(install.items[s]);
				if (step != null)
					dependency.install.Add(step);
			}
			let also = node["alsoInstall"];
			for (int a < (also != null ? also.Count : 0))
				if (also.items[a].kind == .String)
					dependency.alsoInstall.Add(new .(also.items[a].text));
			Dependencies.Add(dependency);
		}
		return true;
	}

	static Check ParseCheck(SaveNode node)
	{
		if (node == null || node.kind != .Object)
			return null;
		let check = new Check();
		if (node["all"] != null)
		{
			check.kind = .All;
			for (let part in node["all"].items)
			{
				let inner = ParseCheck(part);
				if (inner != null)
					check.parts.Add(inner);
			}
			return check;
		}
		if (node["file"] != null) { check.kind = .File; ForPlatform(node["file"], check.value); }
		else if (node["program"] != null) { check.kind = .Program; ForPlatform(node["program"], check.value); }
		else if (node["env"] != null) { check.kind = .Env; ForPlatform(node["env"], check.value); }
		else if (node["command"] != null) { check.kind = .Command; ForPlatform(node["command"], check.value); }
		else if (node["beefLibraries"] != null) { check.kind = .BeefLibraries; ForPlatform(node["beefLibraries"], check.value); }
		else if (node["visualStudio"] != null) { check.kind = .VisualStudio; ForPlatform(node["visualStudio"], check.value); }
		else if (node["libraries"] != null)
		{
			check.kind = .Libraries;
			for (let library in node["libraries"].items)
				if (library.kind == .String)
					check.values.Add(new .(library.text));
			return check;
		}
		// A check for another platform only: nothing to test here.
		if (check.value.IsEmpty)
		{
			delete check;
			return null;
		}
		return check;
	}

	static Step ParseStep(SaveNode node)
	{
		if (node == null || node.kind != .Object)
			return null;
		let step = new Step();
		if (node["download"] != null) { step.kind = .Download; Text(node, "download", step.value); Text(node, "unpack", step.extra); }
		else if (node["run"] != null) { step.kind = .Run; Text(node, "run", step.value); }
		else if (node["runAsAdmin"] != null) { step.kind = .RunAdmin; Text(node, "runAsAdmin", step.value); }
		else if (node["configureMicrosoft"] != null) { step.kind = .ConfigureMicrosoft; Text(node, "configureMicrosoft", step.value); }
		else if (node["write"] != null) { step.kind = .Write; Text(node, "write", step.value); Text(node, "text", step.extra); }
		else if (node["delete"] != null) { step.kind = .Delete; Text(node, "delete", step.value); }
		else if (node["packages"] != null)
		{
			step.kind = .Packages;
			let packages = node["packages"];
			for (int i < packages.Count)
				if (packages.items[i].kind == .String)
					step.packages[new .(packages.keys[i])] = new .(packages.items[i].text);
		}
		else
		{
			delete step;
			return null;
		}
		return step;
	}
}
