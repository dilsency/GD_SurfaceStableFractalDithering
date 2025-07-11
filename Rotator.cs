using Godot;
using System;

public partial class Rotator : Node3D
{
    ulong elapsedTime;
    ulong elapsedTimeStart;

    public override void _Ready()
    {
        // Called every time the node is added to the scene.
        // Initialization here.
        GD.Print("Hello from C# to Godot :)");

        elapsedTimeStart = Godot.Time.GetTicksMsec();
        elapsedTime = 0;
    }

    public override void _Process(double delta)
    {
        // Called every frame. Delta is time since the last frame.
        // Update game logic here.

        //
        elapsedTime = Godot.Time.GetTicksMsec() - elapsedTimeStart;

        //
        bool polarity = true;
        if(elapsedTime % 10000 > 5000){ polarity = false; }

        //
        double rotationAmount = Math.PI / 4 * delta;
        rotationAmount *= (polarity ? 1 : -1);

        this.RotateY((float)rotationAmount);
    }
}
