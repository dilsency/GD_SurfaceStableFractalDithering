using Godot;
using System;


	
public partial class Script01 : Node3D
{
	// when used, skip the "EventHandler" part of the name
	[Signal]
	public delegate void SignalUpdateLightPositionEventHandler(Vector3 lightPosition);
	
	public override void _Ready()
	{
		GD.Print("Script01 initialized");
		//
		this.SignalUpdateLightPosition += SignalUpdateLightPositionCallback;
	}
	
	private void SignalUpdateLightPositionCallback(Vector3 lightPosition)
	{
		GD.Print("update light position!");
	}
}
