using Godot;
using System;

public partial class Rotator : Node3D
{
	ulong elapsedTime;
	ulong elapsedTimeStart;
	
	ulong throttle = 0;
	[Export] ulong throttleMax = 2000;
	
	[Export] bool enabled = true;
	[Export] bool shouldHoldRotate = true;
	[Export] bool shouldChangeDirection = false;
	[Export] bool shouldSnapRotate = true;
	[Export] double timerRotationMax = 2.0;
	
	double timerRotation = 0;
	
	bool buttonHeld = false;
	bool toggleHold = false;
	[Export] float rotationSpeed = 0.05f;
	
	Vector3 lightNormal = new Vector3(0,0,0);


	// when used, skip the "EventHandler" part of the name
	[Signal]
	public delegate void SignalUpdateLightPositionEventHandler(Vector3 lightPosition);

	
	public override void _Ready()
	{
		// Called every time the node is added to the scene.
		// Initialization here.
		GD.Print("Hello from C# to Godot :)");

		elapsedTimeStart = Godot.Time.GetTicksMsec();
		elapsedTime = 0;
		
		
	}
	
	
	public override void _Input(InputEvent @event)
	{
		if (@event.IsActionPressed("ctrl"))
		{
			toggleHold = !toggleHold;
		}
		else if (@event.IsActionReleased("ctrl"))
		{
		}
	}
	

	public override void _Process(double delta)
	{
		// Called every frame. Delta is time since the last frame.
		// Update game logic here.

		//
		elapsedTime = Godot.Time.GetTicksMsec() - elapsedTimeStart;

		//
		if(!enabled){return;}
		
		//
		buttonHeld = Input.IsActionPressed("space");

		//
		bool polarity = true;
		if(shouldChangeDirection == true){
			if(elapsedTime % 10000 > 5000){ polarity = false; }
		}
		
		//
		if(shouldHoldRotate)
		{
			if(buttonHeld || toggleHold)
			{
				double rotationAmount = Math.PI / 4;
				rotationAmount *= rotationSpeed;
				rotationAmount *= (polarity ? 1 : -1);
				this.RotateY((float)rotationAmount);
			}
		}
		else
		{

			if(!shouldSnapRotate)
			{
				//
				double rotationAmount = Math.PI / 4 * delta;
				rotationAmount *= (polarity ? 1 : -1);

				this.RotateY((float)rotationAmount);
			}
			else
			{
					//
					timerRotation += delta;
					if(timerRotation > timerRotationMax)
					{
						double rotationAmount = Math.PI / 4 * timerRotation / 4;
						rotationAmount *= (polarity ? 1 : -1);
						this.RotateY((float)rotationAmount);
						
						timerRotation = 0;
					}
				
			}
		
		}
		
		//
		if(elapsedTime < throttle){return;}
		throttle = elapsedTime + throttleMax;
		
		// update our light position
		// using signals!
		//
		NodePath npLight = new NodePath("%OmniLight3D");
		OmniLight3D lightNode = GetNode<OmniLight3D>(npLight);
		GD.Print("send signal!");
		EmitSignal(SignalName.SignalUpdateLightPosition, lightNode.GlobalPosition);
		
		/*
		// first we need to get the node
		NodePath npLight = new NodePath("%OmniLight3D");
		NodePath npTeapot = new NodePath("%Teapot_Node4");
		
		OmniLight3D lightNode = GetNode<OmniLight3D>(npLight);
		if(lightNode == null){GD.Print("lightNode == null");return;}
		Node3D teapotNode = GetNode<Node3D>(npTeapot);
		if(teapotNode == null){GD.Print("teapotNode == null");return;}
		
		//if(teapotNode is MeshInstance3D){GD.Print("teapotNode is MeshInstance3D");}
		MeshInstance3D teapotNodeCast = (teapotNode as MeshInstance3D);
		if(teapotNodeCast == null){GD.Print("teapotNodeCast == null");return;}
		
		Mesh teapotNodeMesh = teapotNodeCast.Mesh;
		if(teapotNodeMesh == null){GD.Print("teapotNodeMesh == null");return;}
		//lightNormal = lightNode.GlobalPosition.DirectionTo(teapotNode.GlobalPosition);
		
		Material materialUnconverted = teapotNodeMesh.SurfaceGetMaterial(0);
		*/
		
		/*int materialCount = m.GetSurfaceOverrideMaterialCount();
		if(materialCount == null || materialCount <= 0){GD.Print("materialCount == null");return;}
		Material materialUnconverted = m.GetSurfaceOverrideMaterial(0);
		//ShaderMaterial sm = m.GetSurfaceOverrideMaterial(0) as ShaderMaterial;*/
		/*
		if(materialUnconverted == null){GD.Print("materialUnconverted == null");return;}
		(materialUnconverted as ShaderMaterial).SetShaderParameter("light_position", lightNode.GlobalPosition);
		*/
		//(materialUnconverted as ShaderMaterial).SetShaderParameter("light_normal", lightNormal);
		
		//
		//GD.Print("light_position:\n" + lightNode.GlobalPosition);
		/*GD.Print("");
		GD.Print("position of light:\n" + lightNode.GlobalPosition);
		GD.Print("position of teapot:\n" + teapotNode.GlobalPosition);
		GD.Print("light_normal:\n" + lightNormal);*/
	}
}
