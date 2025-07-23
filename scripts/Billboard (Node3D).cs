using Godot;
using System;

public partial class BillboardNode3D : Node3D
{
	ulong elapsedTime;
	ulong elapsedTimeStart;
	ulong throttle;
	[Export] ulong throttleMax = 200;
	
	bool hasRanOnce = false;
	
	Vector3 origin;
	
	Viewport vp;
	Camera3D cam;
	Vector3 targetPosition;
	
	[Export] bool enabled = true;
	[Export] bool targetCam = false;
	[Export] bool useDegInsteadOfRad = true;
	[Export] bool useLookAtFake = true;
	

	public override void _Ready()
	{
		// Called every time the node is added to the scene.
		// Initialization here.
		GD.Print("() init | billboard.cs");

		elapsedTimeStart = Godot.Time.GetTicksMsec();
		elapsedTime = 0;
		throttle = 0;
		
		//
		origin = new Vector3(0,0,0);
		
		//
		vp = GetViewport();
		if(vp == null) {return;}
		cam = vp.GetCamera3D();
		if(cam == null){return;}
		
		//
		if(targetCam == true)
		{
			targetPosition = cam.GlobalPosition;
		}
		else {
			targetPosition = origin;
		}
	}

	public override void _Process(double delta)
	{
		// Called every frame. Delta is time since the last frame.
		// Update game logic here.

		//
		elapsedTime = Godot.Time.GetTicksMsec() - elapsedTimeStart;

		//
		if(elapsedTime < throttle){return;}
		throttle = elapsedTime + throttleMax;

		//
		if(!enabled){return;}

		// rotate to face
		// either camera or center
		if (cam == null) { return; }
		
		//
		if(targetCam == true)
		{
			targetPosition = cam.GlobalPosition;
		}
		
		//
		if(useLookAtFake)
		{
			Vector3 camPositionButYIsReset = new Vector3();
			camPositionButYIsReset.X = cam.GlobalPosition.X;
			camPositionButYIsReset.Y = 0.0f;
			camPositionButYIsReset.Z = cam.GlobalPosition.Z;
			this.LookAt(camPositionButYIsReset);
			return;	
		}

		// look at
		// store x and z though
		/*
		var xOld = cam.Rotation.X;
		var zOld = cam.Rotation.Z;
		this.LookAt(cam.GlobalPosition);
		cam.Rotation.X = xOld;
		cam.Rotation.Z = zOld;
		*/

		//
		/*
		var xdiff = cam.GlobalPosition.X - this.GlobalPosition.X;
		var zdiff = cam.GlobalPosition.Z - this.GlobalPosition.Z;
		var rad = Mathf.Atan2(xdiff, zdiff);
		var deg = Mathf.RadToDeg(rad);

		const float rotationSpeed = 1.0f;

		//
		var res = Vector3.Up * Mathf.LerpAngle(this.Rotation.Y, deg, rotationSpeed);

		this.RotationDegrees = res;
		*/
		
		//
		/*
		if(targetCam == true)
		{
			targetPosition = cam.GlobalPosition;
		}
		*/
		
		// attempt 2 lol
		// z is up!
		var xdiff = targetPosition.X - this.GlobalPosition.X;
		var ydiff = targetPosition.Y - this.GlobalPosition.Y;
		var angleRad = Mathf.Atan2(ydiff, xdiff);
		var angleDeg = Mathf.RadToDeg(angleRad);
		Vector3 res;
		if(useDegInsteadOfRad)
		{
			res = new Vector3(0, angleDeg, 0);
		}
		else {
			res = new Vector3(0, angleRad, 0);
		}
		this.SetRotation(res);
		
		// must be placed last
		if(hasRanOnce){return;}
		hasRanOnce = true;
		
		//
		/*
		GD.Print(xdiff + " xdiff");
		GD.Print(zdiff + " zdiff");
		GD.Print(deg + " deg");
		GD.Print(res + " res");
		*/
	}
}
