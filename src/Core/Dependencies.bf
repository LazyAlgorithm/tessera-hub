using System;
using System.Collections;
using System.IO;
using Tessera;

namespace TesseraHub;

/// Checks for and installs the tools catalog items need (Catalog.Dependency): any check passing means a tool is
/// present; installing runs its steps for this platform. Everything here blocks, so the Hub runs it on a thread
/// (see Task) and shows Status while it does.
static class Dependencies
{
	/// True when the tool is present, by any of its checks.
	public static bool IsFound(Catalog.Dependency dependency)
	{
		if (!dependency.applies)
			return true;
#if BF_PLATFORM_WINDOWS
		// Reuse a registered installation and repair only the managed compiler's settings.
		if (dependency.id == "microsoft-libraries" && !Application.Instance.HasArg("--dependencycheck") && File.Exists(scope $"{Machine.ToolsFolder}/beef/bin/BeefBuild.exe"))
		{
			let settings = scope $"{Machine.ToolsFolder}/beef/bin/BeefSettings.toml";
			if (!HasBeefLibraries(settings)) ConfigureMicrosoft(settings, scope .());
		}
#endif
		for (let check in dependency.found)
		{
			if (Passes(check))
				return true;
		}
		return false;
	}

	static bool Passes(Catalog.Check check)
	{
		let value = scope String();
		Machine.Expand(check.value, value);
		switch (check.kind)
		{
		case .File:
			return File.Exists(value);
		case .Program:
			return Machine.FindProgram(value, scope .());
		case .Env:
			let path = scope String();
			return (Environment.GetEnvironmentVariable(value, path) case .Ok) && !path.IsEmpty && File.Exists(path);
		case .Command:
			return Machine.Succeeds(value);
		case .Libraries:
			for (let library in check.values)
			{
				if (!HasLibrary(library))
					return false;
			}
			return true;
		case .VisualStudio:
			return HasVisualStudio(value);
		case .BeefLibraries:
			return HasBeefLibraries(value);
		case .All:
			for (let part in check.parts)
			{
				if (!Passes(part))
					return false;
			}
			return check.parts.Count > 0;
		}
	}

	/// Checks the managed settings format emitted by the catalog without invoking a shell.
	static bool HasBeefLibraries(StringView settings)
	{
		let text = scope String();
		if (File.ReadAllText(settings, text) case .Err) return false;
		bool section = false, manual = false;
		let paths = scope String();
		for (let raw in text.Split('\n'))
		{
			let line = scope String(raw); line.Trim();
			if (line.StartsWith("[")) { section = line == "[VisualStudio]"; continue; }
			if (!section) continue;
			let equal = line.IndexOf('=');
			if (equal < 0) continue;
			let key = scope String(line.Substring(0, equal)); key.Trim();
			let value = scope String(line.Substring(equal + 1)); value.Trim();
			if (key == "ManuallySet") manual = value == "true";
			if (key == "Lib64Paths") paths.Set(value);
		}
		if (!manual || paths.IsEmpty) return false;
		// The emitted one-line TOML string array also has JSON syntax, including escaped backslashes.
		let directories = SaveNode.FromText(paths);
		defer delete directories;
		if (directories == null || directories.kind != .List) return false;
		for (let library in StringView[3]("libcmt.lib", "kernel32.lib", "ucrt.lib"))
		{
			bool found = false;
			for (let directory in directories.items)
				if (directory.kind == .String && File.Exists(scope $"{directory.text}/{library}")) found = true;
			if (!found) return false;
		}
		return true;
	}

	static bool HasLibrary(StringView name)
	{
		let folders = scope List<StringView>();
		folders.Add("/usr/lib/x86_64-linux-gnu");
		folders.Add("/usr/lib64");
		folders.Add("/usr/lib");
		folders.Add("/lib/x86_64-linux-gnu");
		folders.Add("/usr/local/lib");
		folders.Add("/usr/lib/aarch64-linux-gnu");
		for (let folder in folders)
		{
			let path = scope String(folder);
			path.Append('/');
			path.Append(name);
			if (File.Exists(path))
				return true;
		}
		return false;
	}

	/// Visual Studio (or its Build Tools) with a component, as Microsoft's vswhere reports it.
	static bool HasVisualStudio(StringView component)
	{
#if BF_PLATFORM_WINDOWS
		let programs = scope String();
		Environment.GetEnvironmentVariable("ProgramFiles(x86)", programs).IgnoreError();
		let vswhere = scope String(programs);
		vswhere.Append("\\Microsoft Visual Studio\\Installer\\vswhere.exe");
		if (programs.IsEmpty || !File.Exists(vswhere))
			return false;
		let output = scope String(Machine.DataFolder);
		output.Append("/vswhere.txt");
		let command = scope String();
		Machine.Quote(vswhere, command);
		command.Append(" -latest -products * -requires ");
		command.Append(component);
		command.Append(" -property installationPath > ");
		Machine.Quote(output, command);
		Machine.Run(command);
		let text = scope String();
		File.ReadAllText(output, text).IgnoreError();
		File.Delete(output).IgnoreError();
		text.Trim();
		return !text.IsEmpty;
#else
		return false;
#endif
	}

	static int64 VersionRank(StringView name)
	{
		int64 rank = 0;
		for (let piece in name.Split('.'))
		{
			if (!(Int32.Parse(piece) case .Ok(let part)) || part < 0 || part >= 100000) return -1;
			rank = rank * 100000 + part;
		}
		return rank;
	}

	/// Configure Beef from registered Microsoft tools, retaining unrelated compiler settings.
	public static bool ConfigureMicrosoft(StringView settings, String error)
	{
#if BF_PLATFORM_WINDOWS
		let programs = scope String();
		Environment.GetEnvironmentVariable("ProgramFiles(x86)", programs).IgnoreError();
		let vswhere = scope $"{programs}/Microsoft Visual Studio/Installer/vswhere.exe";
		let output = scope $"{Machine.DataFolder}/microsoft-location.txt";
		let command = scope String();
		Machine.Quote(vswhere, command);
		command.Append(" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath > ");
		Machine.Quote(output, command);
		let vs = scope String();
		if (!File.Exists(vswhere) || Machine.Run(command) != 0 || (File.ReadAllText(output, vs) case .Err))
		{ error.Set("Microsoft C++ Build Tools were not found. Install the C++ tools and Windows SDK, then retry."); return false; }
		File.Delete(output).IgnoreError(); vs.Trim(); vs.Replace('\\', '/');
		let crt = scope String(); int64 newest = -1;
		for (let entry in Directory.EnumerateDirectories(scope $"{vs}/VC/Tools/MSVC"))
		{
			let name = scope String(); entry.GetFileName(name);
			let path = scope String(); entry.GetFilePath(path);
			let rank = VersionRank(name);
			if (rank > newest && File.Exists(scope $"{path}/lib/x64/libcmt.lib"))
			{ newest = rank; crt.Set(scope $"{path}/lib/x64"); }
		}
		let sdk = scope String();
		Environment.GetEnvironmentVariable("WindowsSdkDir", sdk).IgnoreError();
		if (sdk.IsEmpty)
		{
			command.Set("reg query \"HKLM\\SOFTWARE\\Microsoft\\Windows Kits\\InstalledRoots\" /v KitsRoot10 > ");
			Machine.Quote(output, command);
			if (Machine.Run(command) == 0)
			{
				let text = scope String(); File.ReadAllText(output, text).IgnoreError();
				for (let line in text.Split('\n'))
				{
					let at = line.IndexOf("REG_SZ");
					if (at >= 0 && line.Contains("KitsRoot10")) { sdk.Set(line.Substring(at + 6)); sdk.Trim(); }
				}
			}
			File.Delete(output).IgnoreError();
		}
		if (sdk.IsEmpty) sdk.Set(scope $"{programs}/Windows Kits/10");
		let um = scope String(), ucrt = scope String(); newest = -1;
		for (let entry in Directory.EnumerateDirectories(scope $"{sdk}/Lib"))
		{
			let name = scope String(); entry.GetFileName(name);
			let path = scope String(); entry.GetFilePath(path);
			let rank = VersionRank(name);
			if (rank > newest && File.Exists(scope $"{path}/um/x64/kernel32.lib") && File.Exists(scope $"{path}/ucrt/x64/ucrt.lib"))
			{ newest = rank; um.Set(scope $"{path}/um/x64"); ucrt.Set(scope $"{path}/ucrt/x64"); }
		}
		if (crt.IsEmpty || um.IsEmpty || ucrt.IsEmpty)
		{ error.Set("Microsoft's installation is missing x64 CRT or Windows SDK libraries. Repair the C++ Build Tools installation and retry."); return false; }
		crt.Replace('\\', '/'); um.Replace('\\', '/'); ucrt.Replace('\\', '/');
		let previous = scope String(); File.ReadAllText(settings, previous).IgnoreError();
		let text = scope String(); bool skip = false;
		for (let raw in previous.Split('\n'))
		{
			let line = scope String(raw); line.Trim();
			if (line.StartsWith("[")) skip = line == "[VisualStudio]";
			if (!skip) text.AppendF("{}\n", raw);
		}
		if (previous.IsEmpty) text.Set("FileVersion = 1\n");
		text.AppendF("\n[VisualStudio]\nManuallySet = true\nBin32Path = \"\"\nBin64Path = \"\"\nLib32Paths = []\nLib64Paths = [\"{}\", \"{}\", \"{}\"]\n", crt, um, ucrt);
		let folder = scope String(); Path.GetDirectoryPath(settings, folder).IgnoreError();
		Directory.CreateDirectory(folder).IgnoreError();
		if (File.WriteAllText(settings, text) case .Err) { error.Set(scope $"Could not write Beef settings at {settings}."); return false; }
		return HasBeefLibraries(settings);
#else
		error.Set("Microsoft C++ tools configuration is available on Windows."); return false;
#endif
	}

	/// The dependencies an item needs that are missing here, with what they bring along, in install order.
	public static void Missing(Catalog catalog, Catalog.Item item, List<Catalog.Dependency> missing)
	{
		for (let id in item.requires)
		{
			let dependency = catalog.FindDependency(id);
			if (dependency == null || IsFound(dependency) || missing.Contains(dependency))
				continue;
			// What it writes into is installed first.
			for (let also in dependency.alsoInstall)
			{
				let other = catalog.FindDependency(also);
				if (other != null && !missing.Contains(other) && (other.id == "beef" || !IsFound(other)))
					missing.Add(other);
			}
			missing.Add(dependency);
		}
	}

	/// The command that installs packages with this system's package manager (through pkexec, which asks for the
	/// password in a window of its own), or empty when there is no known package manager or no pkexec.
	public static void PackageCommand(Catalog.Step step, String command)
	{
		for (let entry in step.packages)
		{
			if (!Machine.FindProgram(entry.key, scope .()))
				continue;
			let install = scope String();
			switch (entry.key)
			{
			case "apt-get": install.AppendF("apt-get install -y {}", entry.value);
			case "dnf": install.AppendF("dnf install -y {}", entry.value);
			case "pacman": install.AppendF("pacman -S --needed --noconfirm {}", entry.value);
			case "zypper": install.AppendF("zypper install -y {}", entry.value);
			default: continue;
			}
			command.Set(install);
			return;
		}
	}

	/// Installs one dependency. status is told what is happening; false, with error, on failure.
	public static bool Install(Catalog.Dependency dependency, Task task)
	{
		let log = scope String(Machine.DataFolder);
		log.Append("/install.log");
		Machine.AppendText(log, scope $"\n== {dependency.name}\n");
		for (let step in dependency.install)
		{
			if (task.Cancelled)
				return task.Fail("Cancelled.");
			let value = scope String();
			Machine.Expand(step.value, value);
			let extra = scope String();
			Machine.Expand(step.extra, extra);
			switch (step.kind)
			{
			case .Download:
				let name = scope String();
				Path.GetFileName(value, name);
				let file = scope String(Machine.DataFolder);
				file.Append("/downloads/");
				Directory.CreateDirectory(file).IgnoreError();
				file.Append(name);
				if (!task.Download(value, file, scope $"Downloading {dependency.name}"))
					return false;
				if (!extra.IsEmpty && !task.Unpack(file, extra, scope $"Unpacking {dependency.name}"))
					return false;
				// A raw installer must remain available for the following RunAdmin step.
				if (!extra.IsEmpty) File.Delete(file).IgnoreError();
			case .Run:
				task.SetStatus(scope $"Setting up {dependency.name} (this can take a few minutes)", -1);
				if (Machine.Run(value, log) != 0)
					return task.Fail(scope $"Setting up {dependency.name} failed. See {log}.");
			case .RunAdmin:
				task.SetStatus(scope $"Installing {dependency.name}; approve Windows' administrator prompt", -1);
				let code = Machine.Run(value, log, true);
				if (code == 1223) return task.Fail("Administrator approval was declined. Run Install again to retry.");
				if (code != 0 && code != 3010) return task.Fail(scope $"Installing {dependency.name} failed (exit {code}). See {log} and Microsoft's installer logs in your TEMP folder.");
				if (code == 3010) Machine.AppendText(log, "\nInstallation succeeded. Windows reports a restart is needed; the Hub will not restart your machine.\n");
			case .ConfigureMicrosoft:
				let reason = scope String();
				if (!ConfigureMicrosoft(value, reason)) return task.Fail(reason);
			case .Write:
				let folder = scope String();
				if (Path.GetDirectoryPath(value, folder) case .Ok)
					Directory.CreateDirectory(folder).IgnoreError();
				if (File.WriteAllText(value, extra) case .Err)
					return task.Fail(scope $"Could not write {value}.");
			case .Delete:
				if (Directory.Exists(value))
					Directory.DelTree(value).IgnoreError();
				else
					File.Delete(value).IgnoreError();
			case .Packages:
				let command = scope String();
				PackageCommand(step, command);
				if (command.IsEmpty || !Machine.FindProgram("pkexec", scope .()))
					return task.Fail(scope $"Install {dependency.name} with your package manager, then try again.");
				task.SetStatus(scope $"Installing {dependency.name} (enter your password when asked)", -1);
				if (Machine.Run(scope $"pkexec sh -c \"{command}\"", log) != 0)
					return task.Fail(scope $"The package manager did not install {dependency.name}. See {log}.");
			}
		}
		if (!IsFound(dependency))
			return task.Fail(scope $"{dependency.name} was set up but still cannot be found. See {log}.");
		return true;
	}
}
