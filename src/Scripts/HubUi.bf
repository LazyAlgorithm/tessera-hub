using System;
using System.Collections;
using Tessera;

namespace TesseraHub;

/// The Hub's window: the list of games and the engine, the selected one's page, settings, and asking before tools
/// are installed. Drives UI/hub.tui; everything that does the work is in Core/.
[Component]
class HubUi : Component
{
	UIDocument mDocument;
	UIElement mGames, mEngines, mEntryTemplate, mToolTemplate;
	UIElement mPage, mSettings, mDialog, mBody, mBanner;

	/// The selected item's id; empty with Settings shown.
	String mSelected = new .() ~ delete _;
	bool mShowSettings;
	/// One piece of work at a time.
	Task mTask ~ delete _;
	/// Shown under the buttons after work finishes or fails: (text, good news).
	String mMessage = new .() ~ delete _;
	String mMessageFor = new .() ~ delete _;
	bool mMessageGood;
	/// The tools the open dialog would install, and the item after them.
	List<Catalog.Dependency> mDialogTools = new .() ~ delete _;
	String mDialogItem = new .() ~ delete _;
	bool mRestartAfterTask;
	bool mDialogLaunch;
	int32 mListVersion = -1;
	int32 mVersion;

	public override void Start()
	{
		Library.Load();
		if (Application.Instance.HasArg("--dependencycheck"))
		{
			if (Application.Instance.HasArg("--configure-windows-libraries"))
			{
				let error = scope String();
				let configured = Dependencies.ConfigureMicrosoft(scope $"{Machine.ToolsFolder}/beef/bin/BeefSettings.toml", error);
				Console.WriteLine($"CONFIGURE MICROSOFT: {configured} {error}");
			}
			for (let dependency in Library.Catalog.Dependencies)
				Console.WriteLine($"DEPENDENCY CHECK {dependency.id}: {Dependencies.IsFound(dependency)}");
			return;
		}
		StartCheck();
	}

	bool FindElements()
	{
		if (mDocument == null)
			mDocument = GetComponent<UIDocument>();
		if (mDocument == null || mDocument.Data == null || mDocument.Data.root == null)
			return false;
		if (mGames != null)
			return true;
		mGames = mDocument.Find("games");
		mEngines = mDocument.Find("engines");
		mEntryTemplate = mDocument.Find("entrytemplate");
		mToolTemplate = mDocument.Find("tooltemplate");
		mPage = mDocument.Find("page");
		mSettings = mDocument.Find("settings");
		mDialog = mDocument.Find("dialog");
		mBody = mDocument.Find("body");
		mBanner = mDocument.Find("banner");
		mDialog.visible = false;
		Find("version").SetText(scope $"Tessera Hub {Library.HubVersion}");
		Find("folderpath").SetText(Machine.DataFolder);
		Find("toolspath").SetText(Machine.ToolsFolder);
		return mGames != null;
	}

	UIElement Find(StringView id) => mDocument.Find(id);

	static UIElement FindClass(UIElement element, StringView name)
	{
		if (element.HasClass(name))
			return element;
		for (let child in element.children)
		{
			let found = FindClass(child, name);
			if (found != null)
				return found;
		}
		return null;
	}

	/// A copy of a template, placed in parent, without the template's id (which hides it).
	static UIElement Stamp(UIElement template, UIElement parent)
	{
		let copy = template.Clone();
		copy.attributes.Remove("id");
		copy.parent = parent;
		parent.children.Add(copy);
		return copy;
	}

	static void Clear(UIElement element)
	{
		ClearAndDeleteItems!(element.children);
	}

	Catalog.Item Selected => Library.Catalog.FindItem(mSelected);

	bool Busy => mTask != null && !mTask.Finished;

	// ---- every frame ----

	public override void Update()
	{
		if (!FindElements())
			return;
		if (Library.Poll())
			mVersion++;
		if (mTask != null && mTask.Finished)
			FinishTask();
		if (mListVersion != mVersion)
			BuildList();
		if (mSelected.IsEmpty && !mShowSettings && Library.Catalog.Items.Count > 0)
			Select(Library.Catalog.Items[0].id);
		RefreshList();
		Find("settingsentry").SetClass("selected", mShowSettings);
		mPage.visible = !mShowSettings;
		mSettings.visible = mShowSettings;
		if (mShowSettings)
			RefreshSettings();
		else
			RefreshPage();
		RefreshHubUpdate();
	}

	void BuildList()
	{
		mListVersion = mVersion;
		Clear(mGames);
		Clear(mEngines);
		int games = 0, engines = 0;
		for (let item in Library.Catalog.Items)
		{
			let engine = item.kind == "engine";
			let entry = Stamp(mEntryTemplate, engine ? mEngines : mGames);
			entry.attributes.Set("item", item.id);
			FindClass(entry, "entryname").SetText(item.name);
			if (!item.icon.IsEmpty)
				FindClass(entry, "entryicon").attributes.Set("src", item.icon);
			FindClass(entry, "entrybadge").visible = item.beta;
			if (engine) engines++; else games++;
		}
		Find("gamessection").visible = games > 0;
		Find("enginesection").visible = engines > 0;
	}

	void RefreshList()
	{
		UIElement[2] lists = .(mGames, mEngines);
		for (let list in lists)
		{
			for (let entry in list.children)
			{
				let id = entry.attributes.Get("item");
				let item = Library.Catalog.FindItem(id);
				if (item == null)
					continue;
				entry.SetClass("selected", !mShowSettings && id == mSelected);
				let state = FindClass(entry, "entrystate");
				let installed = Library.FindInstalled(id);
				state.SetClass("stateupdate", false);
				state.SetClass("stateready", false);
				if (Busy && mTask.For == id)
					state.SetText(mTask.Title);
				else if (!item.Available)
					state.SetText("Not for this computer yet");
				else if (installed == null)
					state.SetText("Not installed");
				else if (Library.HasUpdate(item))
				{
					state.SetText("Update available");
					state.SetClass("stateupdate", true);
				}
				else
				{
					state.SetText(item.kind == "engine" ? "Installed" : "Ready to play");
					state.SetClass("stateready", true);
				}
			}
		}
	}

	void Select(StringView id)
	{
		mSelected.Set(id);
		mShowSettings = false;
		if (mMessageFor != id)
			mMessage.Clear();
	}

	static void Size(int64 bytes, String output)
	{
		if (bytes <= 0)
			output.Append("-");
		else if (bytes >= 1024 * 1024 * 1024)
			output.AppendF("{0:0.0} GB", bytes / (1024.0 * 1024 * 1024));
		else
			output.AppendF("{0:0} MB", Math.Max(bytes / (1024.0 * 1024), 1));
	}

	void RefreshPage()
	{
		let item = Selected;
		if (item == null)
		{
			mBody.visible = false;
			return;
		}
		mBody.visible = true;
		let installed = Library.FindInstalled(item.id);
		let latest = Library.LatestOf(item.id);
		let working = Busy && mTask.For == item.id;
		StringView accent = item.accent.IsEmpty ? (StringView)"#4cc3f0" : item.accent;

		// The banner keeps its shape (2.5 to 1) at any window width; the text starts over its lower part.
		let width = mPage.width;
		if (width > 0)
		{
			let height = Math.Min(width / 2.5f, 470);
			mBanner.SetStyle("width", scope $"{width:0}");
			mBanner.SetStyle("height", scope $"{height:0}");
			mBody.SetStyle("top", scope $"{Math.Max(height - 170, 150):0}");
		}
		mBanner.attributes.Set("src", item.banner);

		Find("title").SetText(item.name);
		Find("badge").visible = item.beta;
		Find("summary").SetText(item.summary);

		// The main button: install, play, or what is happening.
		let primary = Find("primary");
		bool enabled = !Busy;
		if (working)
		{
			primary.SetText("WORKING");
			enabled = false;
		}
		else if (!item.Available)
		{
			primary.SetText("NOT AVAILABLE");
			enabled = false;
		}
		else if (installed != null)
			primary.SetText(item.kind == "engine" ? "OPEN" : "PLAY");
		else if (latest == null)
		{
			primary.SetText(Library.LatestErrors.ContainsKeyAlt(item.id) ? "NO RELEASE YET" : "CHECKING");
			enabled = false;
		}
		else
			primary.SetText("INSTALL");
		primary.SetStyle("background-color", enabled ? accent : (StringView)"#2a3647");
		primary.SetStyle("color", enabled ? (StringView)"#07111b" : (StringView)"#7c8a9c");
		primary.attributes.Set("disabled", enabled ? "" : "1");

		Find("updatebutton").visible = installed != null && Library.HasUpdate(item) && !working;
		Find("folderbutton").visible = installed != null;
		Find("removebutton").visible = installed != null && !working;

		let progress = Find("progress");
		progress.visible = working;
		if (working)
		{
			let status = scope String();
			mTask.GetStatus(status);
			Find("progresstext").SetText(status.IsEmpty ? mTask.Title : status);
			let bar = Find("progressbar");
			let fraction = mTask.Fraction;
			if (fraction >= 0)
				bar.value = fraction;
			else
			{
				// Not known: a slow sweep, so it is plainly still going.
				bar.value = (float)(Math.Sin(Time.RealTime * 2.2) * 0.5 + 0.5);
			}
			bar.SetStyle("color", accent);
		}

		let message = Find("message");
		message.visible = !mMessage.IsEmpty && mMessageFor == item.id && !working;
		message.SetText(mMessage);
		message.SetClass("messageok", mMessageGood);

		// Facts.
		let installedText = scope String();
		if (installed == null)
			installedText.Append("Not installed");
		else
			installedText.AppendF("{}{}", installed.tag, installed.beta ? "  (beta)" : "");
		Find("factinstalled").SetText(installedText);
		let latestText = scope String();
		if (latest != null)
			latestText.AppendF("{}{}", latest.tag, latest.beta ? "  (beta)" : "");
		else if (Library.LatestErrors.TryGetAlt(item.id, ?, let error))
			latestText.Append(error);
		else
			latestText.Append("Checking...");
		Find("factlatest").SetText(latestText);
		let sizeText = scope String();
		Size(latest != null ? latest.assetSize : 0, sizeText);
		Find("factsize").SetText(sizeText);
		let needs = scope String();
		for (let id in item.requires)
		{
			let dependency = Library.Catalog.FindDependency(id);
			if (dependency == null || !dependency.applies)
				continue;
			if (!needs.IsEmpty)
				needs.Append(", ");
			needs.Append(dependency.name);
		}
		Find("factneedsbox").visible = !needs.IsEmpty;
		Find("factneeds").SetText(needs);

		let notes = scope String();
		if (latest != null)
		{
			// Release notes are Markdown: show them as plain lines, and not too many.
			int lines = 0;
			for (var line in latest.notes.Split('\n'))
			{
				line.Trim();
				if (line.IsEmpty)
					continue;
				if (++lines > 6)
				{
					notes.Append("...");
					break;
				}
				let plain = scope String(line);
				plain.Replace("**", "");
				plain.Replace("`", "");
				if (plain.StartsWith("- ") || plain.StartsWith("* "))
				{
					plain.Remove(0, 2);
					plain.Insert(0, "•  ");
				}
				notes.AppendF("{}{}", notes.IsEmpty ? "" : "\n", plain);
			}
		}
		Find("noteslabel").visible = !notes.IsEmpty;
		Find("notes").visible = !notes.IsEmpty;
		Find("notes").SetText(notes);
	}

	void RefreshSettings()
	{
		Find("betatoggle").value = Library.Betas ? 1 : 0;
		let checkedText = scope String();
		if (Busy && mTask.For == "check")
			checkedText.Append("Checking now...");
		else if (Library.LastChecked.Year < 2000)
			checkedText.Append("The Hub checks when it starts.");
		else
			checkedText.AppendF("Last checked at {}:{}{}.", Library.LastChecked.Hour, Library.LastChecked.Minute < 10 ? "0" : "", Library.LastChecked.Minute);
		Find("checkedtext").SetText(checkedText);
	}

	void RefreshHubUpdate()
	{
		let panel = Find("hubupdate");
		panel.visible = Library.HubUpdate != null;
		if (Library.HubUpdate != null)
		{
			if (Busy && mTask.For == "hub")
			{
				let status = scope String();
				mTask.GetStatus(status);
				Find("hubupdatetext").SetText(status);
			}
			else
				Find("hubupdatetext").SetText(scope $"{Library.HubUpdate.tag} is ready. Click to install it and restart.");
		}
	}

	// ---- work ----

	void Run(Task task)
	{
		delete mTask;
		mTask = task;
		mTask.Start();
	}

	void StartCheck()
	{
		if (Busy)
			return;
		Run(new Task("Checking for updates", "check", new (task) => Library.Check(task)));
	}

	void FinishTask()
	{
		let ok = mTask.Succeeded;
		let error = scope String();
		mTask.GetError(error);
		let forId = scope String(mTask.For);
		let title = scope String(mTask.Title);
		DeleteAndNullify!(mTask);
		if (forId == "check")
			return;
		if (forId == "hub")
		{
			if (ok)
			{
				Library.RestartHub();
				Application.Instance.Running = false;
			}
			else
				Log.Error(scope $"Hub update failed: {error}");
			return;
		}
		mMessageFor.Set(forId);
		mMessageGood = ok;
		let item = Library.Catalog.FindItem(forId);
		if (ok)
			mMessage.Set(scope $"{item != null ? item.name : forId} is ready.");
		else
			mMessage.Set(error.IsEmpty ? scope $"{title} did not finish." : error);
	}

	/// Installs the tools in mDialogTools, then the item.
	void StartInstall(Catalog.Item item, bool update)
	{
		let latest = Library.LatestOf(item.id);
		if (latest == null)
			return;
		let release = new Release();
		latest.CopyTo(release);
		let tools = new List<Catalog.Dependency>();
		tools.AddRange(mDialogTools);
		mDialogTools.Clear();
		let catalogItem = item;
		mMessage.Clear();
		Run(new Task(update ? "Updating" : "Installing", item.id, new [=](task) =>
			{
				defer { delete release; delete tools; }
				for (let tool in tools)
				{
					if (!Dependencies.Install(tool, task))
						return false;
				}
				return Library.Install(catalogItem, release, task);
			}));
	}

	// ---- handlers (named in hub.tui) ----

	void OnSelect(UIElement source)
	{
		Select(source.attributes.Get("item"));
	}

	void OnShowSettings()
	{
		mShowSettings = true;
	}

	void OnPrimary()
	{
		let item = Selected;
		if (item == null || Busy || !item.Available)
			return;
		if (Library.FindInstalled(item.id) != null)
		{
			mDialogTools.Clear();
			Dependencies.Missing(Library.Catalog, item, mDialogTools);
			if (!mDialogTools.IsEmpty)
			{
				mDialogLaunch = true;
				mDialogItem.Set(item.id);
				ShowDialog(item);
				return;
			}
			if (!Library.Launch(item))
			{
				mMessageFor.Set(item.id);
				mMessageGood = false;
				mMessage.Set("Could not start it. Its files may have been moved; Uninstall and install it again.");
			}
			return;
		}
		Install(item, false);
	}

	void OnUpdate()
	{
		let item = Selected;
		if (item != null && !Busy)
			Install(item, true);
	}

	/// Installs or updates, asking first if tools are missing.
	void Install(Catalog.Item item, bool update)
	{
		mDialogLaunch = false;
		if (Library.LatestOf(item.id) == null)
			return;
		mDialogTools.Clear();
		Dependencies.Missing(Library.Catalog, item, mDialogTools);
		if (mDialogTools.IsEmpty)
		{
			StartInstall(item, update);
			return;
		}
		mDialogItem.Set(item.id);
		ShowDialog(item);
	}

	void ShowDialog(Catalog.Item item)
	{
		Find("dialogtitle").SetText(scope $"{item.name} needs {(mDialogTools.Count == 1 ? "a tool" : "some tools")} first");
		Find("dialogtext").SetText(scope $"{(mDialogTools.Count == 1 ? "This is" : "These are")} not on this computer yet. The Hub can download and set {(mDialogTools.Count == 1 ? "it" : "them")} up now, then {(mDialogLaunch ? "start" : "install")} {item.name}. Nothing is changed until you choose Install Everything.");
		let list = Find("dialoglist");
		Clear(list);
		bool licences = false;
		for (let tool in mDialogTools)
		{
			let row = Stamp(mToolTemplate, list);
			FindClass(row, "toolname").SetText(tool.name);
			FindClass(row, "toolsize").SetText(tool.size);
			FindClass(row, "toolsummary").SetText(tool.summary);
			let licence = FindClass(row, "toollicence");
			licence.visible = tool.NeedsLicence;
			if (tool.NeedsLicence)
			{
				licences = true;
				licence.attributes.Set("url", tool.licenceUrl);
				FindClass(row, "toollicencetext").SetText(scope $"Licence: {tool.licenceName} (read it)");
			}
		}
		Find("dialogtotal").SetText(licences ? "Choosing Install Everything accepts the licences above." : "Some steps can take a few minutes.");
		Find("dialogok").SetText(licences ? "Accept and Install" : "Install Everything");
		mDialog.visible = true;
	}

	void OnDialogInstall()
	{
		mDialog.visible = false;
		let item = Library.Catalog.FindItem(mDialogItem);
		if (item != null && !Busy)
		{
			if (!mDialogLaunch)
				StartInstall(item, Library.FindInstalled(item.id) != null);
			else
			{
				let tools = new List<Catalog.Dependency>();
				tools.AddRange(mDialogTools);
				mDialogTools.Clear();
				let launchItem = item;
				Run(new Task("Repairing tools", item.id, new [=](task) =>
					{
						defer delete tools;
						for (let tool in tools)
							if (!Dependencies.Install(tool, task)) return false;
						return Library.Launch(launchItem) || task.Fail("Tools are ready, but the installed program could not be started.");
					}));
			}
		}
	}

	/// Clicks on the shade around the dialog go nowhere (not to what is behind it).
	void OnDialogBackdrop()
	{
	}

	void OnDialogCancel()
	{
		mDialog.visible = false;
		mDialogTools.Clear();
	}

	void OnLicence(UIElement source)
	{
		let url = source.attributes.Get("url");
		if (!url.IsEmpty)
			Machine.Open(url);
	}

	void OnCancel()
	{
		mTask?.Cancel();
	}

	void OnShowFolder()
	{
		let item = Selected;
		let installed = item != null ? Library.FindInstalled(item.id) : null;
		if (installed != null)
			Machine.Open(installed.folder);
	}

	void OnUninstall()
	{
		let item = Selected;
		if (item == null || Busy)
			return;
		let error = scope String();
		mMessageFor.Set(item.id);
		mMessageGood = Library.Uninstall(item, error);
		mMessage.Set(mMessageGood ? scope $"{item.name} was removed." : error);
	}

	void OnBetas(UIElement source)
	{
		Library.Betas = source.value > 0.5f;
		Library.SaveState();
		StartCheck();
	}

	void OnCheck()
	{
		StartCheck();
	}

	void OnOpenHubFolder()
	{
		Machine.Open(Machine.DataFolder);
	}

	void OnOpenToolsFolder()
	{
		Machine.Open(Machine.ToolsFolder);
	}

	void OnUpdateHub()
	{
		let update = Library.HubUpdate;
		if (update == null || Busy)
			return;
		let release = new Release();
		update.CopyTo(release);
		Run(new Task("Updating the Hub", "hub", new [=](task) =>
			{
				defer delete release;
				return Library.UpdateHub(release, task);
			}));
	}
}
