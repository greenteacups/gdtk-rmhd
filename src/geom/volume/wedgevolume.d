// wedgevolume.d

module geom.volume.wedgevolume;

import std.conv;
import std.math;
import std.stdio;
import nm.complex;
import nm.number;

import geom.elements;
import geom.gpath;
import geom.surface;
import geom.volume.parametricvolume;


class WedgeVolume : ParametricVolume {
public:
    ParametricSurface face0123; // The bottom surface.
    double dtheta; // The angle through which points from the bottom surface will be swept.
    Vector3[8] p; // Corner points for the defined volume.

    this(const ParametricSurface face0123, double dtheta)
    {
        this.face0123 = face0123.dup();
        this.dtheta = dtheta;
        p[0] = face0123(0.0, 0.0);
        p[1] = face0123(1.0, 0.0);
        p[2] = face0123(1.0, 1.0);
        p[3] = face0123(0.0, 1.0);
        p[4] = sweep_through_arc(p[0], dtheta);
        p[5] = sweep_through_arc(p[1], dtheta);
        p[6] = sweep_through_arc(p[2], dtheta);
        p[7] = sweep_through_arc(p[3], dtheta);
    }
    
    this(ref const(WedgeVolume) other)
    {
        face0123 = other.face0123.dup();
        dtheta = other.dtheta;
        foreach(i; 0 .. 8) this.p[i] = other.p[i].dup();
    }

    override WedgeVolume dup() const
    {
        return new WedgeVolume(this.face0123, this.dtheta);
    }

    override Vector3 opCall(double r, double s, double t) const
    // Locate a point within the volume by first interpolating on
    // the bottom surface and then sweeping about the x-axis.
    // Input:
    //     r: interpolation parameter i-direction west-->east, 0.0<=r<=1.0
    //     s: interpolation parameter j-direction south-->north, 0.0<=s<=1.0 
    //     t: interpolation parameter k-direction bottom-->top, 0.0<=t<=1.0
    // Returns:
    //     a Vector3 value for the point.
    {
        Vector3 p_rs = face0123(r, s);
        return sweep_through_arc(p_rs, t*dtheta); 
    } // end opCall

    override string toString() const
    {
        string repr = "WedgeVolume(face0123=" ~ to!string(face0123);
        repr ~= ", dtheta=" ~ to!string(dtheta) ~ ")";
        return repr;
    } // end toString

private:
    Vector3 sweep_through_arc(const Vector3 p0, double theta) const
    {
        // We want to rotate the point about the x-axis, according to the right-hand rule.
        // Angles are measured from the y-axis, positive as we swing around toward the z-axis.
        // Refer to PJ's workbook page 36, 2017-07-01
        double r = sqrt((p0.y.re)^^2 + (p0.z.re)^^2);
        double theta0 = atan2(p0.z.re, p0.y.re);
        double theta1 = theta0+theta;
        return Vector3(p0.x.re, r*cos(theta1), r*sin(theta1));
    } // end sweep_through_arc()
} // end WedgeVolume

version(wedgevolume_test) {
    import util.msg_service;
    int main() {
        Vector3[8] p;
        p[0] = Vector3(0.0, 0.1, 0.0);
        p[1] = Vector3(1.0, 0.1, 0.0);
        p[2] = Vector3(1.0, 1.1, 0.0);
        p[3] = Vector3(0.0, 1.1, 0.0);
        ParametricSurface my_face = new CoonsPatch(p[0], p[1], p[2], p[3]);
        auto my_box = new WedgeVolume(my_face, 0.1);
        auto d = my_box(0.1, 0.1, 0.5);
        // writeln("my_box=", my_box, " d=", d);
        // expect p0.x=0.1 p0.y=0.2 and have set t=0.5, dtheta=0.1
        assert(approxEqualVectors(d, Vector3(0.1, 0.2*cos(0.05), 0.2*sin(0.05))),
               failedUnitTest());
        return 0;
    }
} // end wedgevolume_test
