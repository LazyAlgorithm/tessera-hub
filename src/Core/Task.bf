using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tessera;

namespace TesseraHub;

/// Work the Hub does on a thread of its own (installing, updating, setting up tools) while the window shows how far
/// it has got. The work reports through SetStatus, and Download and Unpack report for it.
class Task
{
	/// What the work is, for the window: "Installing Ringfall".
	public String Title = new .() ~ delete _;
	/// The catalog item or dependency it is for.
	public String For = new .() ~ delete _;

	String mStatus = new .() ~ delete _;
	String mError = new .() ~ delete _;
	Monitor mLock = new .() ~ delete _;
	Thread mThread ~ { if (_ != null) { _.Join(); delete _; } };
	delegate bool(Task task) mWork ~ delete _;
	float mFraction = -1;
	bool mCancelled;
	bool mFinished;
	bool mSucceeded;

	public this(StringView title, StringView forId, delegate bool(Task task) work)
	{
		Title.Set(title);
		For.Set(forId);
		mWork = work;
	}

	public void Start()
	{
		mThread = new Thread(new => Run);
		mThread.Start(false);
	}

	void Run()
	{
		bool ok = false;
		ok = mWork(this);
		using (mLock.Enter())
		{
			if (!ok && mError.IsEmpty)
				mError.Set(mCancelled ? "Cancelled." : "Something went wrong.");
			mSucceeded = ok;
		}
		mFinished = true;
	}

	public bool Finished => mFinished;
	public bool Succeeded => mSucceeded;
	public bool Cancelled => mCancelled;
	/// 0 to 1, or -1 while how long is left is not known.
	public float Fraction => mFraction;

	public void Cancel() { mCancelled = true; }

	public void GetStatus(String output)
	{
		using (mLock.Enter())
			output.Append(mStatus);
	}

	public void GetError(String output)
	{
		using (mLock.Enter())
			output.Append(mError);
	}

	/// What is happening now, and how far along (-1: not known).
	public void SetStatus(StringView text, float fraction)
	{
		using (mLock.Enter())
			mStatus.Set(text);
		mFraction = fraction;
	}

	/// Stops the work with a message. Returns false, for `return task.Fail(...)`.
	public bool Fail(StringView message)
	{
		using (mLock.Enter())
			mError.Set(message);
		return false;
	}

	static void Megabytes(int64 bytes, String output)
	{
		output.AppendF("{0:0.0} MB", bytes / (1024.0 * 1024.0));
	}

	/// Downloads url to file, showing label and the progress.
	public bool Download(StringView url, StringView file, StringView label)
	{
		SetStatus(label, 0);
		let error = scope String();
		let text = scope String();
		let ok = Http.Download(url, file, error, scope [&](done, total) =>
			{
				text.Set(label);
				text.Append("  ");
				Megabytes(done, text);
				if (total > 0)
				{
					text.Append(" of ");
					Megabytes(total, text);
				}
				SetStatus(text, total > 0 ? (float)((double)done / total) : -1);
				return !mCancelled;
			});
		if (!ok)
			return Fail(mCancelled ? "Cancelled." : scope $"Could not download {url}: {error}");
		return true;
	}

	/// Unpacks a .zip, .tar.gz or .tar.xz into folder.
	public bool Unpack(StringView file, StringView folder, StringView label)
	{
		SetStatus(label, 0);
		Directory.CreateDirectory(folder).IgnoreError();
		if (file.EndsWith(".zip", .OrdinalIgnoreCase))
		{
			let error = scope String();
			if (!ZipFile.Extract(file, folder, error, scope (done, total) => SetStatus(label, (float)done / Math.Max(total, 1))))
				return Fail(scope $"Could not unpack {file}: {error}");
			return true;
		}
		// Tar files: every system the Hub runs on has tar (Windows since 10).
		SetStatus(label, -1);
		let command = scope String("tar -xf ");
		Machine.Quote(file, command);
		command.Append(" -C ");
		Machine.Quote(folder, command);
		if (Machine.Run(command) != 0)
			return Fail(scope $"Could not unpack {file}.");
		return true;
	}

	/// The SHA-256 of a file, as lowercase hex.
	public static bool HashFile(StringView file, String output)
	{
		let stream = scope FileStream();
		if (stream.Open(file, .Read, .Read) case .Err)
			return false;
		let sha = scope System.Security.Cryptography.SHA256();
		uint8[65536] buffer = ?;
		while (true)
		{
			switch (stream.TryRead(.(&buffer, buffer.Count)))
			{
			case .Ok(let count):
				if (count == 0)
				{
					let hash = sha.Finish();
					let hex = scope String();
					hash.ToString(hex);
					hex.ToLower();
					output.Append(hex);
					return true;
				}
				sha.Update(.(&buffer, count));
			case .Err:
				return false;
			}
		}
	}
}
