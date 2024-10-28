using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// This is a quick-and-dirty solution to release-only crashes in builds. 
/// In Unity, some resources must only be disposed from the main thread. This class 
/// provides a simple way to do that for code which may be called from another thread, 
/// e.g. class finalizers called from the GC thread.
///
/// To-do: Look into a nicer implementation, maybe via PlayerLoop injection?
/// </summary>
public class MainThreadResourceDisposer : MonoBehaviour
{
	private static MainThreadResourceDisposer instance = null;

	private static List<IDisposable> queuedResources = new List<IDisposable>();
	
	
	[RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
	private static void Initialize()
	{
		GameObject go = new GameObject("MainThreadResourceDisposer");
		DontDestroyOnLoad(go);
		instance = go.AddComponent<MainThreadResourceDisposer>();
	}

	private void OnDestroy() 
	{
		DisposeResources();
	}

	public static void QueueForRelease(IDisposable resource)
    {
		#if UNITY_EDITOR
		// Maintaining old behaviour in Editor, for now.
		resource?.Dispose();
		#else
		queuedResources.Add(resource);
		// Note: Can not (reliably?) set enabled = true from here, otherwise I would disable the component after disposals.
		#endif
    }

	private void Update()
	{
		DisposeResources();
	}

	void DisposeResources()
	{
		int c = queuedResources.Count;
		if (c > 0) 
		{
			foreach (IDisposable resource in queuedResources) resource?.Dispose();
			queuedResources.Clear();
		}
	}
}