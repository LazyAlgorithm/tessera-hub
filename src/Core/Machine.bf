using System;
using System.Collections;
using System.IO;
using Tessera;

namespace TesseraHub;

/// What the Hub needs from the operating system: its folders, finding and running programs, environment variables.
static class Machine
{
	[CLink] static extern int32 system(char8* command);
#if BF_PLATFORM_WINDOWS
	[CLink] static extern int32 _putenv_s(char8* name, char8* value);
	[CLink] static extern uint32 GetLastError();
#else
	[CLink] static extern int32 setenv(char8* name, char8* value, int32 overwrite);
#endif

	static String sData = new .() ~ delete _;
	static String sTools = new .() ~ delete _;

	static void UserData(String path)
	{
#if BF_PLATFORM_WINDOWS
		Environment.GetEnvironmentVariable("LOCALAPPDATA", path).IgnoreError();
		path.Replace('\\', '/');
#elif BF_PLATFORM_MACOS
		Environment.GetEnvironmentVariable("HOME", path).IgnoreError();
		path.Append("/Library/Application Support");
#else
		if (!(Environment.GetEnvironmentVariable("XDG_DATA_HOME", path) case .Ok) || path.IsEmpty)
		{
			path.Clear();
			Environment.GetEnvironmentVariable("HOME", path).IgnoreError();
			path.Append("/.local/share");
		}
#endif
	}

	/// The Hub's own folder: installed games and the engine, its settings and downloads in progress.
	public static String DataFolder
	{
		get
		{
			if (sData.IsEmpty)
			{
				UserData(sData);
				sData.Append("/Tessera Hub");
				Directory.CreateDirectory(sData).IgnoreError();
			}
			return sData;
		}
	}

	/// Where tools are installed: the folder the Tessera editor looks in for them (Tessera's Toolchain.Folder).
	public static String ToolsFolder
	{
		get
		{
			if (sTools.IsEmpty)
			{
				// Isolated fixtures for the opt-in dependency diagnostic; ordinary launches use user data.
				if (Application.Instance.HasArg("--dependencycheck") && Application.Instance.GetArg("--tools-folder", sTools) && !sTools.IsEmpty) return sTools;
				UserData(sTools);
				sTools.Append("/Tessera/toolchain");
				Directory.CreateDirectory(sTools).IgnoreError();
			}
			return sTools;
		}
	}

	/// Replaces {tools}, {tools_toml} (backslashes doubled, for a TOML string on Windows) and {hub} in catalog text.
	public static void Expand(StringView text, String output)
	{
		output.Set(text);
		let tools = scope String(ToolsFolder);
		let toml = scope String(ToolsFolder);
#if BF_PLATFORM_WINDOWS
		toml.Replace("/", "\\\\");
#endif
		output.Replace("{tools_toml}", toml);
		output.Replace("{tools}", tools);
		output.Replace("{hub}", DataFolder);
	}

	public static void SetEnv(StringView name, StringView value)
	{
#if BF_PLATFORM_WINDOWS
		_putenv_s(scope String(name).CStr(), scope String(value).CStr());
#else
		setenv(scope String(name).CStr(), scope String(value).CStr(), 1);
#endif
	}

	/// Finds a program on PATH (on Windows, NAME.exe).
	public static bool FindProgram(StringView program, String outPath)
	{
		let path = scope String();
		Environment.GetEnvironmentVariable("PATH", path).IgnoreError();
#if BF_PLATFORM_WINDOWS
		let separator = ';';
		let suffix = ".exe";
#else
		let separator = ':';
		let suffix = "";
#endif
		for (let folder in path.Split(separator))
		{
			if (folder.IsEmpty)
				continue;
			let candidate = scope String(folder);
			candidate.Append('/');
			candidate.Append(program);
			candidate.Append(suffix);
			// The Microsoft Store's stand-in for Python only offers to install it.
			if (File.Exists(candidate) && !candidate.Contains("WindowsApps"))
			{
				outPath.Set(candidate);
				return true;
			}
		}
		return false;
	}

	/// Runs a command through the system's shell and waits. Output goes to logPath when given.
	public static int32 Run(StringView command, StringView logPath = default, bool administrator = false)
	{
		let line = scope String(command);
		if (!logPath.IsEmpty)
		{
			line.Append(" >> ");
			Quote(logPath, line);
			line.Append(" 2>&1");
		}
#if BF_PLATFORM_WINDOWS
		// Through cmd, without a console window flashing up over the Hub. cmd strips the first and last quote of a
		// line that starts with one, so give it a pair to strip.
		let comspec = scope String();
		if (!(Environment.GetEnvironmentVariable("ComSpec", comspec) case .Ok) || comspec.IsEmpty)
			comspec.Set("C:\\Windows\\System32\\cmd.exe");
		let info = scope System.Diagnostics.ProcessStartInfo();
		info.SetFileName(comspec);
		info.SetArguments(scope $"/d /s /c \"{line}\"");
		info.UseShellExecute = administrator;
		if (administrator) info.SetVerb("runas");
		info.CreateNoWindow = true;
		let process = scope System.Diagnostics.SpawnedProcess();
		if (process.Start(info) case .Err)
		{
			let error = GetLastError();
			if (!logPath.IsEmpty) AppendText(logPath, scope $"\nWindows could not start the installer (error {error}).\n");
			return error != 0 ? (int32)error : -1;
		}
		process.WaitFor();
		return (int32)process.ExitCode;
#else
		return system(line.CStr());
#endif
	}

	/// Runs a command quietly; true if it succeeded.
	public static bool Succeeds(StringView command)
	{
#if BF_PLATFORM_WINDOWS
		return Run(scope $"{command} > NUL 2>&1") == 0;
#else
		return Run(scope $"{command} > /dev/null 2>&1") == 0;
#endif
	}

	/// Starts a program without waiting for it, in its own folder.
	public static void Start(StringView program, StringView arguments = default)
	{
		let folder = scope String();
		Path.GetDirectoryPath(program, folder).IgnoreError();
		let line = scope String();
#if BF_PLATFORM_WINDOWS
		let info = scope System.Diagnostics.ProcessStartInfo();
		info.SetFileName(program);
		if (!arguments.IsEmpty)
			info.SetArguments(arguments);
		info.SetWorkingDirectory(folder);
		info.UseShellExecute = false;
		let process = scope System.Diagnostics.SpawnedProcess();
		process.Start(info).IgnoreError();
#else
		line.Append("cd ");
		Quote(folder, line);
		line.Append(" && (");
		Quote(program, line);
		if (!arguments.IsEmpty)
		{
			line.Append(' ');
			line.Append(arguments);
		}
		line.Append(" > /dev/null 2>&1 &)");
		system(line.CStr());
#endif
	}

	/// Opens a folder or web address with whatever the desktop uses for it.
	public static void Open(StringView target)
	{
		let line = scope String();
#if BF_PLATFORM_WINDOWS
		line.Append("start \"\" ");
#elif BF_PLATFORM_MACOS
		line.Append("open ");
#else
		line.Append("xdg-open ");
#endif
		Quote(target, line);
#if BF_PLATFORM_WINDOWS
		Run(line);
#else
		line.Append(" > /dev/null 2>&1 &");
		system(line.CStr());
#endif
	}

	/// Adds text to the end of a file (made if missing).
	public static void AppendText(StringView path, StringView text)
	{
		let stream = scope FileStream();
		if (stream.Open(path, .Append, .Write, .ReadWrite) case .Ok)
			stream.Write(Span<uint8>((uint8*)text.Ptr, text.Length)).IgnoreError();
	}

	/// Wraps a path in quotes for the shell.
	public static void Quote(StringView path, String output)
	{
		output.Append('"');
		for (let c in path.RawChars)
		{
#if BF_PLATFORM_WINDOWS
			if (c == '"')
				continue;
			if (c == '/')
			{
				output.Append('\\');
				continue;
			}
#else
			if (c == '"' || c == '\\' || c == '$' || c == '`')
				output.Append('\\');
#endif
			output.Append(c);
		}
		output.Append('"');
	}
}
