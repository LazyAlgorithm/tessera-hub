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
		case .All:
			for (let part in check.parts)
			{
				if (!Passes(part))
					return false;
			}
			return check.parts.Count > 0;
		}
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
				if (other != null && !missing.Contains(other))
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
				File.Delete(file).IgnoreError();
			case .Run:
				task.SetStatus(scope $"Setting up {dependency.name} (this can take a few minutes)", -1);
				if (Machine.Run(value, log) != 0)
					return task.Fail(scope $"Setting up {dependency.name} failed. See {log}.");
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
