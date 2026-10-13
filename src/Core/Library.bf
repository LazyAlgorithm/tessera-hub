using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tessera;

namespace TesseraHub;

/// What is installed, what the newest releases are, and installing, updating, starting and removing.
/// Everything here is used from the window's thread except the work inside a Task, which goes through the lock.
static class Library
{
	public class Installed
	{
		public String id = new .() ~ delete _;
		public String tag = new .() ~ delete _;
		public String name = new .() ~ delete _;
		public String folder = new .() ~ delete _;
		public String run = new .() ~ delete _;
		public bool beta;
	}

	/// Where the Hub's own releases are.
	public const String HubRepo = "LazyAlgorithm/tessera-hub";
	/// The catalog the Hub reads when it starts; the copy in its assets is used when this cannot be fetched.
	public const String CatalogUrl = "https://raw.githubusercontent.com/LazyAlgorithm/tessera-hub/main/src/Data/catalog.json";

	public static Catalog Catalog = new .() ~ delete _;
	public static List<Installed> InstalledItems = new .() ~ DeleteContainerAndItems!(_);
	/// The newest release of each item, by id, once checked.
	public static Dictionary<String, Release> Latest = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	/// Why an item's newest release could not be found, by id.
	public static Dictionary<String, String> LatestErrors = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	/// Offer pre-releases (betas). On by default: most of what the Hub offers is in beta.
	public static bool Betas = true;
	/// The Hub's own version (the release tag it was built for; "dev" when built by hand).
	public static String HubVersion = new .("dev") ~ delete _;
	/// A newer Hub, once checked.
	public static Release HubUpdate ~ delete _;
	public static DateTime LastChecked;

	static Monitor sLock = new .() ~ delete _;
	// Results of a check, made on a thread and taken in by Poll.
	static Catalog sCheckedCatalog ~ delete _;
	static Dictionary<String, Release> sCheckedLatest ~ DeleteDictionaryAndKeysAndValues!(_);
	static Dictionary<String, String> sCheckedErrors ~ DeleteDictionaryAndKeysAndValues!(_);
	static Release sCheckedHub ~ delete _;
	static bool sCheckReady;

	static String StatePath => scope:: $"{Machine.DataFolder}/library.json";

	// ---- starting up ----

	/// Reads the built-in catalog and what is installed.
	public static void Load()
	{
		let version = scope String();
		if (Assets.ReadText("Data/version.txt", version))
		{
			version.Trim();
			if (!version.IsEmpty)
				HubVersion.Set(version);
		}
		let catalog = scope String();
		if (Assets.ReadText("Data/catalog.json", catalog))
			Catalog.Parse(catalog, scope .());
		LoadState();
		CleanUpAfterSelfUpdate();
	}

	static void LoadState()
	{
		let text = scope String();
		if (File.ReadAllText(StatePath, text) case .Err)
			return;
		let root = SaveNode.FromText(text);
		defer delete root;
		if (root == null || root.kind != .Object)
			return;
		let betas = root["betas"];
		if (betas != null && betas.kind == .Bool)
			Betas = betas.integer != 0;
		let installed = root["installed"];
		for (int i < (installed != null ? installed.Count : 0))
		{
			let node = installed.items[i];
			let entry = new Installed();
			Copy(node, "id", entry.id);
			Copy(node, "tag", entry.tag);
			Copy(node, "name", entry.name);
			Copy(node, "folder", entry.folder);
			Copy(node, "run", entry.run);
			let beta = node["beta"];
			entry.beta = beta != null && beta.integer != 0;
			// A folder deleted by hand is not installed any more.
			if (entry.id.IsEmpty || !Directory.Exists(entry.folder))
			{
				delete entry;
				continue;
			}
			InstalledItems.Add(entry);
		}
	}

	static void Copy(SaveNode node, StringView key, String output)
	{
		let value = node[key];
		if (value != null && value.kind == .String)
			output.Set(value.text);
	}

	public static void SaveState()
	{
		let root = new SaveNode(.Object);
		defer delete root;
		root.Set("betas", SaveNode.MakeBool(Betas));
		let list = new SaveNode(.List);
		using (sLock.Enter())
		{
			for (let entry in InstalledItems)
			{
				let node = new SaveNode(.Object);
				node.Set("id", SaveNode.MakeString(entry.id));
				node.Set("tag", SaveNode.MakeString(entry.tag));
				node.Set("name", SaveNode.MakeString(entry.name));
				node.Set("folder", SaveNode.MakeString(entry.folder));
				node.Set("run", SaveNode.MakeString(entry.run));
				node.Set("beta", SaveNode.MakeBool(entry.beta));
				list.items.Add(node);
			}
		}
		root.Set("installed", list);
		let text = scope String();
		root.ToText(text);
		File.WriteAllText(StatePath, text).IgnoreError();
	}

	// ---- looking things up ----

	public static Installed FindInstalled(StringView id)
	{
		using (sLock.Enter())
		{
			for (let entry in InstalledItems)
				if (entry.id == id)
					return entry;
		}
		return null;
	}

	public static Release LatestOf(StringView id)
	{
		if (Latest.TryGetAlt(id, ?, let release))
			return release;
		return null;
	}

	public static bool HasUpdate(Catalog.Item item)
	{
		let installed = FindInstalled(item.id);
		let latest = LatestOf(item.id);
		return installed != null && latest != null && latest.tag != installed.tag;
	}

	/// Where an item is installed: <Hub folder>/Games/<id>, or Engine/<id>.
	public static void FolderFor(Catalog.Item item, String output)
	{
		output.AppendF("{}/{}/{}", Machine.DataFolder, item.kind == "engine" ? "Engine" : "Games", item.id);
	}

	// ---- checking for updates ----

	/// Fetches the catalog and every item's newest release. Run as a Task; Poll takes in the results.
	public static bool Check(Task task)
	{
		task.SetStatus("Checking for updates", -1);
		let catalog = new Catalog();
		let text = scope String();
		let error = scope String();
		bool fetched = Http.GetText(CatalogUrl, text, error) && catalog.Parse(text, error) && catalog.Items.Count > 0;
		if (!fetched)
		{
			// Offline, or the catalog moved: keep using the one the Hub has.
			text.Clear();
			Assets.ReadText("Data/catalog.json", text);
			catalog.Parse(text, error);
		}
		bool betas = Betas;
		let latest = new Dictionary<String, Release>();
		let errors = new Dictionary<String, String>();
		for (let item in catalog.Items)
		{
			if (task.Cancelled)
				break;
			if (!item.Available)
				continue;
			let release = new Release();
			let message = scope String();
			if (Releases.Latest(item, betas, release, message))
				latest[new .(item.id)] = release;
			else
			{
				delete release;
				errors[new .(item.id)] = new .(message);
			}
		}
		// The Hub itself.
		Release hub = null;
		if (HubVersion != "dev")
		{
			let hubItem = scope Catalog.Item();
			hubItem.repo.Set(HubRepo);
			hubItem.asset.AppendF("TesseraHub-{}.zip", TesseraHub.Catalog.Platform == "windows" ? "Windows" : (TesseraHub.Catalog.Platform == "macos" ? "Mac" : "Linux"));
			hub = new Release();
			if (!Releases.Latest(hubItem, betas, hub, scope .()) || hub.tag == HubVersion)
				DeleteAndNullify!(hub);
		}
		using (sLock.Enter())
		{
			delete sCheckedCatalog;
			sCheckedCatalog = catalog;
			if (sCheckedLatest != null)
				DeleteDictionaryAndKeysAndValues!(sCheckedLatest);
			sCheckedLatest = latest;
			if (sCheckedErrors != null)
				DeleteDictionaryAndKeysAndValues!(sCheckedErrors);
			sCheckedErrors = errors;
			delete sCheckedHub;
			sCheckedHub = hub;
			sCheckReady = true;
		}
		return true;
	}

	/// Takes in the results of a finished check. True when there were some.
	public static bool Poll()
	{
		using (sLock.Enter())
		{
			if (!sCheckReady)
				return false;
			sCheckReady = false;
			delete Catalog;
			Catalog = sCheckedCatalog;
			sCheckedCatalog = null;
			DeleteDictionaryAndKeysAndValues!(Latest);
			Latest = sCheckedLatest;
			sCheckedLatest = null;
			DeleteDictionaryAndKeysAndValues!(LatestErrors);
			LatestErrors = sCheckedErrors;
			sCheckedErrors = null;
			delete HubUpdate;
			HubUpdate = sCheckedHub;
			sCheckedHub = null;
		}
		LastChecked = DateTime.Now;
		return true;
	}

	// ---- installing ----

	/// Downloads and unpacks the newest release of item, replacing what was installed. Run as a Task.
	public static bool Install(Catalog.Item item, Release release, Task task)
	{
		let downloads = scope String(Machine.DataFolder);
		downloads.Append("/downloads");
		Directory.CreateDirectory(downloads).IgnoreError();
		let file = scope $"{downloads}/{item.asset}";
		if (!task.Download(release.assetUrl, file, scope $"Downloading {item.name}"))
			return false;
		task.SetStatus("Checking the download", -1);
		let error = scope String();
		if (!Releases.Verify(release, file, item.asset, error))
		{
			File.Delete(file).IgnoreError();
			return task.Fail(error);
		}
		if (task.Cancelled)
			return task.Fail("Cancelled.");

		// Unpacked beside the installed copy first, so a failure leaves that working.
		let folder = scope String();
		FolderFor(item, folder);
		let fresh = scope $"{folder}.new";
		if (Directory.Exists(fresh))
			Directory.DelTree(fresh).IgnoreError();
		if (!task.Unpack(file, fresh, scope $"Installing {item.name}"))
		{
			Directory.DelTree(fresh).IgnoreError();
			return false;
		}
		File.Delete(file).IgnoreError();
		if (!File.Exists(scope $"{fresh}/{item.run}"))
		{
			Directory.DelTree(fresh).IgnoreError();
			return task.Fail(scope $"The release does not contain {item.run}.");
		}
		task.SetStatus(scope $"Installing {item.name}", 1);
		if (Directory.Exists(folder) && (Directory.DelTree(folder) case .Err))
		{
			Directory.DelTree(fresh).IgnoreError();
			return task.Fail(scope $"Could not replace {folder}. Close {item.name} if it is running, then try again.");
		}
		if (Directory.Move(fresh, folder) case .Err)
			return task.Fail(scope $"Could not move the new files into {folder}.");

		using (sLock.Enter())
		{
			var entry = (Installed)null;
			for (let existing in InstalledItems)
				if (existing.id == item.id)
					entry = existing;
			if (entry == null)
			{
				entry = new Installed();
				entry.id.Set(item.id);
				InstalledItems.Add(entry);
			}
			entry.tag.Set(release.tag);
			entry.name.Set(release.name);
			entry.beta = release.beta;
			entry.folder.Set(folder);
			entry.run.Set(item.run);
		}
		SaveState();
		return true;
	}

	public static bool Uninstall(Catalog.Item item, String error)
	{
		let installed = FindInstalled(item.id);
		if (installed == null)
			return true;
		if (Directory.Exists(installed.folder) && (Directory.DelTree(installed.folder) case .Err))
		{
			error.Set(scope $"Could not remove {installed.folder}. Close {item.name} if it is running, then try again.");
			return false;
		}
		using (sLock.Enter())
		{
			InstalledItems.Remove(installed);
			delete installed;
		}
		SaveState();
		return true;
	}

	/// Starts an installed item.
	public static bool Launch(Catalog.Item item)
	{
		let installed = FindInstalled(item.id);
		if (installed == null)
			return false;
		let program = scope $"{installed.folder}/{installed.run}";
		if (!File.Exists(program))
			return false;
		Machine.Start(program);
		return true;
	}

	// ---- the Hub updating itself ----

	static void HubFolder(String output)
	{
		Environment.GetExecutableFilePath(output);
		output.Replace('\\', '/');
		let slash = output.LastIndexOf('/');
		if (slash >= 0)
			output.RemoveToEnd(slash);
	}

	/// Downloads the newer Hub and puts its files in place of these. A running program cannot be overwritten on
	/// Windows but can be renamed, so each file is moved aside (name.old, removed at the next start) first.
	public static bool UpdateHub(Release release, Task task)
	{
		let asset = scope String();
		Path.GetFileName(release.assetUrl, asset);
		let file = scope $"{Machine.DataFolder}/downloads/{asset}";
		Directory.CreateDirectory(scope $"{Machine.DataFolder}/downloads").IgnoreError();
		if (!task.Download(release.assetUrl, file, "Downloading the new Tessera Hub"))
			return false;
		let error = scope String();
		if (!Releases.Verify(release, file, asset, error))
			return task.Fail(error);
		let unpacked = scope $"{Machine.DataFolder}/hub-update";
		if (Directory.Exists(unpacked))
			Directory.DelTree(unpacked).IgnoreError();
		if (!task.Unpack(file, unpacked, "Unpacking the new Tessera Hub"))
			return false;
		File.Delete(file).IgnoreError();
		// The zip holds one folder (TesseraHub-Linux/...).
		let source = scope String(unpacked);
		for (let entry in Directory.EnumerateDirectories(unpacked))
		{
			source.Clear();
			entry.GetFilePath(source);
			break;
		}
		let target = scope String();
		HubFolder(target);
		task.SetStatus("Installing the new Tessera Hub", 1);
		for (let entry in Directory.EnumerateFiles(source))
		{
			let name = scope String();
			entry.GetFileName(name);
			let from = scope $"{source}/{name}";
			let to = scope $"{target}/{name}";
			let aside = scope $"{to}.old";
			File.Delete(aside).IgnoreError();
			if (File.Exists(to) && (File.Move(to, aside) case .Err))
				return task.Fail(scope $"Could not replace {to}. Is the Hub's folder read-only?");
			if (File.Move(from, to) case .Err)
			{
				File.Move(aside, to).IgnoreError();
				return task.Fail(scope $"Could not write {to}.");
			}
		}
#if !BF_PLATFORM_WINDOWS
		Machine.Run(scope $"chmod +x \"{target}/TesseraHub\"");
#endif
		Directory.DelTree(unpacked).IgnoreError();
		return true;
	}

	/// Starts the updated Hub (after UpdateHub); the caller then closes this one.
	public static void RestartHub()
	{
		let folder = scope String();
		HubFolder(folder);
#if BF_PLATFORM_WINDOWS
		Machine.Start(scope $"{folder}/TesseraHub.exe");
#else
		Machine.Start(scope $"{folder}/TesseraHub");
#endif
	}

	static void CleanUpAfterSelfUpdate()
	{
		let folder = scope String();
		HubFolder(folder);
		for (let entry in Directory.EnumerateFiles(folder, "*.old"))
		{
			let path = scope String();
			entry.GetFilePath(path);
			File.Delete(path).IgnoreError();
		}
	}
}
