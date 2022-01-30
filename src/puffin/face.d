// face.d -- Part of the Puffin steady-flow calculator.
//
// PA Jacobs
// 2022-01-22
//
module face;

import std.format;
import std.math;

import geom;
import gas;
import gasflow;
import config;
import flow;
import cell;


class Face2D {
public:
    CQIndex cqi;
    Vector3 pos;
    Vector3* p0, p1; // pointers to vertices at each end of face
    Vector3 n; // unit normal (to right when looking from p0 to p1)
    Vector3 t1; // unit tangent (from p0 to p1)
    double area; // per unit depth for 2D planar, per radian for axisymmetric
    //
    double[] F; // Flux vector
    //
    Cell2D[2] left_cells; // References to cells on the left, starting with closest.
    Cell2D[2] right_cells; // References to cells on the right, starting with closest.
    //
    // Workspace for the Osher-type flux calculator.
    GasState stateLstar, stateRstar, stateX0;

    this(GasModel gmodel, CQIndex cqi)
    {
        this.cqi = new CQIndex(cqi);
        pos = Vector3();
        F.length = cqi.n;
        // Workspace for Osher-type flux calculator.
        stateLstar = new GasState(gmodel);
        stateRstar = new GasState(gmodel);
        stateX0 = new GasState(gmodel);
    }

    this(ref const(Face2D) other)
    {
        cqi = new CQIndex(other.cqi);
        pos = Vector3(other.pos);
        F = other.F.dup;
        stateLstar = new GasState(other.stateLstar);
        stateRstar = new GasState(other.stateRstar);
        stateX0 = new GasState(other.stateX0);
    }

    override
    string toString() const
    {
        string repr = "Face2D(";
        repr ~= format("pos=%s, n=%s, t1=%s, area=%g", pos, n, t1, area);
        repr ~= format(", F=%s", F);
        repr ~= ")";
        return repr;
    }

    @nogc
    void compute_geometry(bool axiFlag)
    // Update the geometric properties from vertex data.
    {
        t1 = *p1; t1 -= *p0; t1.normalize();
        Vector3 t2 = Vector3(0.0, 0.0, 1.0);
        cross(n, t1, t2); n.normalize();
        area = distance_between(*p1, *p0);
        pos = *p0; pos += *p1; pos *= 0.5;
        if (axiFlag) { area *= pos.y; }
        return;
    }

    @nogc
    bool is_shock(double compression_tol=-0.01, double shear_tol=0.20)
    // A compression in the normal velocity field will have
    // a decrease in normal velocity in the direction of the face normal.
    // If the shear velocity is too high, we will suppress the shock value.
    // compression_tol: a value of -0.30 is default for Eilmer, however,
    //   we expect somewhat weak shocks in our space-marching solution.
    // shear_tol: a value of 0.20 is default for Eilmer.
    {
        auto fsL = left_cells[0].fs;
        auto fsR = right_cells[0].fs;
        // We have two cells interacting.
        // Compare the relative gas velocities normal to the face.
        double velxL = geom.dot(fsL.vel, n);
        double velxR = geom.dot(fsR.vel, n);
        double aL = fsL.gas.a;
        double aR = fsR.gas.a;
        double a_min = (aL < aR) ? aL : aR;
        double comp = (velxR-velxL)/a_min;
        //
        double velyL = geom.dot(fsL.vel, t1);
        double velyR = geom.dot(fsR.vel, t1);
        double sound_speed = 0.5*(aL+aR);
        double shear = fabs(velyL-velyR)/sound_speed;
        //
        return ((shear < shear_tol) && (comp < compression_tol));
    } // end is_shock()

    @nogc
    void calculate_flux(FlowState2D fsL, FlowState2D fsR, GasModel gmodel, FluxCalcCode flux_calc)
    // Compute the face's flux vector from left and right flow states.
    {
        final switch (flux_calc) {
        case FluxCalcCode.ausmdv:
            calculate_flux_ausmdv(fsL, fsR, gmodel);
            break;
        case FluxCalcCode.hanel:
            calculate_flux_hanel(fsL, fsR, gmodel);
            break;
        case FluxCalcCode.riemann:
            calculate_flux_riemann(fsL, fsR, gmodel);
            break;
        case FluxCalcCode.ausmdv_plus_hanel:
            calculate_flux_ausmdv_plus_hanel(fsL, fsR, gmodel);
            break;
        case FluxCalcCode.riemann_plus_hanel:
            calculate_flux_riemann_plus_hanel(fsL, fsR, gmodel);
            break;
        }
    } // end calculate_flux()

    @nogc
    void calculate_flux_ausmdv_plus_hanel(FlowState2D fsL, FlowState2D fsR, GasModel gmodel)
    // Compute the face's flux vector from left and right flow states.
    // We actually delegate the detailed calculation to one of the other calculators
    // depending on the shock indicator.
    {
        if (left_cells[0].shock_flag || right_cells[0].shock_flag) {
            calculate_flux_hanel(fsL, fsR, gmodel);
        } else {
            calculate_flux_ausmdv(fsL, fsR, gmodel);
        }
        return;
    }

    @nogc
    void calculate_flux_riemann_plus_hanel(FlowState2D fsL, FlowState2D fsR, GasModel gmodel)
    // Compute the face's flux vector from left and right flow states.
    // We actually delegate the detailed calculation to one of the other calculators
    // depending on the shock indicator.
    {
        if (left_cells[0].shock_flag || right_cells[0].shock_flag) {
            calculate_flux_hanel(fsL, fsR, gmodel);
        } else {
            calculate_flux_riemann(fsL, fsR, gmodel);
        }
        return;
    }

    @nogc
    void calculate_flux_riemann(FlowState2D fsL, FlowState2D fsR, GasModel gmodel)
    // Compute the face's flux vector from left and right flow states.
    // The core of this calculation is the one-dimensional Riemann solver
    // from the gasflow module.
    {
        Vector3 velL = Vector3(fsL.vel);
        Vector3 velR = Vector3(fsR.vel);
        velL.transform_to_local_frame(n, t1);
        velR.transform_to_local_frame(n, t1);
        double[5] rsol = osher_riemann(fsL.gas, fsR.gas, velL.x, velR.x,
                                       stateLstar, stateRstar, stateX0, gmodel);
        double rho = stateX0.rho;
        double p = stateX0.p;
        double u = gmodel.internal_energy(stateX0);
        double velx = rsol[4];
        double vely = (velx < 0.0) ? velL.y : velR.y;
        double massFlux = rho*velx;
        Vector3 momentum = Vector3(massFlux*velx+p, massFlux*vely);
        momentum.transform_to_global_frame(n, t1);
        F[cqi.mass] = massFlux;
        F[cqi.xMom] = momentum.x;
        F[cqi.yMom] = momentum.y;
        F[cqi.totEnergy] = massFlux*(u+p/rho+0.5*(velx*velx+vely*vely));
        if (cqi.n_species > 1) {
            foreach (i; 0 .. cqi.n_species) {
                F[cqi.species+i] = massFlux * ((velx < 0.0) ? fsL.gas.massf[i] : fsR.gas.massf[i]);
            }
        }
        foreach (i; 0 .. cqi.n_modes) {
            F[cqi.modes+i] = massFlux * ((velx < 0.0) ? fsL.gas.u_modes[i] : fsR.gas.u_modes[i]);
        }
        bool allFinite = true;
        foreach (e; F) { if (!isFinite(e)) { allFinite = false; } }
        if (!allFinite) {
            debug { import std.stdio;  writeln("face=", this); }
            throw new Exception("At least one flux quantity is not finite.");
        }
        return;
    } // end calculate_flux()

    @nogc
    void calculate_flux_ausmdv(FlowState2D fsL, FlowState2D fsR, GasModel gmodel)
    // Compute the face's flux vector from left and right flow states.
    // Wada and Liou's flux calculator, implemented from details in their AIAA paper,
    // with hints from Ian Johnston.
    // Y. Wada and M. -S. Liou (1994)
    // A flux splitting scheme with high-resolution and robustness for discontinuities.
    // AIAA-94-0083.
    {
        Vector3 velL = Vector3(fsL.vel);
        Vector3 velR = Vector3(fsR.vel);
        velL.transform_to_local_frame(n, t1);
        velR.transform_to_local_frame(n, t1);
        //
        double rhoL = fsL.gas.rho;
        double pL = fsL.gas.p;
        double pLrL = pL/rhoL;
        double velxL = velL.x;
        double velyL = velL.y;
        double uL = gmodel.internal_energy(fsL.gas);
        double aL = fsL.gas.a;
        double keL = 0.5*(velxL*velxL + velyL*velyL);
        double HL = uL + pLrL + keL;
        //
        double rhoR = fsR.gas.rho;
        double pR = fsR.gas.p;
        double pRrR = pR/rhoR;
        double velxR = velR.x;
        double velyR = velR.y;
        double uR = gmodel.internal_energy(fsR.gas);
        double aR = fsR.gas.a;
        double keR = 0.5*(velxR*velxR + velyR*velyR);
        double HR = uR + pR/rhoR + keR;
        //
        // This is the main part of the flux calculator.
        //
        // Weighting parameters (eqn 32) for velocity splitting.
        double alphaL = 2.0*pLrL/(pLrL+pRrR);
        double alphaR = 2.0*pRrR/(pLrL+pRrR);
        // Common sound speed (eqn 33) and Mach numbers.
        double am = fmax(aL, aR);
        double ML = velxL/am;
        double MR = velxR/am;
        // Left state:
        // pressure splitting (eqn 34)
        // and velocity splitting (eqn 30)
        double pLplus, velxLplus;
        double dvelxL = 0.5 * (velxL + fabs(velxL));
        if (fabs(ML) <= 1.0) {
            pLplus = pL*(ML+1.0)*(ML+1.0)*(2.0-ML)*0.25;
            velxLplus = alphaL*((velxL+am)*(velxL+am)/(4.0*am) - dvelxL) + dvelxL;
        } else {
            pLplus = pL * dvelxL / velxL;
            velxLplus = dvelxL;
        }
        // Right state:
        // pressure splitting (eqn 34)
        // and velocity splitting (eqn 31)
        double pRminus, velxRminus;
        double dvelxR = 0.5*(velxR-fabs(velxR));
        if (fabs(MR) <= 1.0) {
            pRminus = pR*(MR-1.0)*(MR-1.0)*(2.0+MR)*0.25;
            velxRminus = alphaR*(-(velxR-am)*(velxR-am)/(4.0*am) - dvelxR) + dvelxR;
        } else {
            pRminus = pR * dvelxR / velxR;
            velxRminus = dvelxR;
        }
        // The mass flux. (eqn 29)
        double massL = velxLplus*rhoL;
        double massR = velxRminus*rhoR;
        double mass_half = massL+massR;
        // Pressure flux (eqn 34)
        double p_half = pLplus + pRminus;
        // Momentum flux: normal direction
        // Compute blending parameter s (eqn 37),
        // the momentum flux for AUSMV (eqn 21) and AUSMD (eqn 21)
        // and blend (eqn 36).
        double dp = pL - pR;
        const double K_SWITCH = 10.0;
        dp = K_SWITCH * fabs(dp) / fmin(pL, pR);
        double s = 0.5 * fmin(1.0, dp);
        double rvel2_AUSMV = massL*velxL + massR*velxR;
        double rvel2_AUSMD = 0.5*(mass_half*(velxL+velxR) - fabs(mass_half)*(velxR-velxL));
        double rvel2_half = (0.5+s)*rvel2_AUSMV + (0.5-s)*rvel2_AUSMD;
        // Assemble components of the flux vector (eqn 36).
        F[cqi.mass] = mass_half;
        double vely = (mass_half >= 0.0) ? velyL : velyR;
        Vector3 momentum = Vector3(rvel2_half+p_half, mass_half*vely);
        momentum.transform_to_global_frame(n, t1);
        F[cqi.xMom] = momentum.x;
        F[cqi.yMom] = momentum.y;
        double H = (mass_half >= 0.0) ? HL : HR;
        F[cqi.totEnergy] = mass_half*H;
        if (cqi.n_species > 1) {
            foreach (i; 0 .. cqi.n_species) {
                double massf = (mass_half >= 0.0) ? fsL.gas.massf[i] : fsR.gas.massf[i];
                F[cqi.species+i] = mass_half*massf;
            }
        }
        foreach (i; 0 .. cqi.n_modes) {
            double u_mode = (mass_half >= 0.0) ? fsL.gas.u_modes[i] : fsR.gas.u_modes[i];
            F[cqi.modes+i] = mass_half*u_mode;
        }
        //
        bool allFinite = true;
        foreach (e; F) { if (!isFinite(e)) { allFinite = false; } }
        if (!allFinite) {
            debug { import std.stdio;  writeln("face=", this); }
            throw new Exception("At least one flux quantity is not finite.");
        }
        return;
    } // end calculate_flux_ausmdv()

    @nogc
    void calculate_flux_hanel(FlowState2D fsL, FlowState2D fsR, GasModel gmodel)
    // Compute the face's flux vector from left and right flow states.
    // Implemented from Y. Wada and M. S. Liou details in their AIAA paper
    // Y. Wada and M. -S. Liou (1997)
    // An accurate and robust flux splitting scheme for shock and contact discontinuities.
    // with reference to....
    // Hanel, Schwane, & Seider's 1987 paper
    // On the accuracy of upwind schemes for the solution of the Navier-Stokes equations
    {
        Vector3 velL = Vector3(fsL.vel);
        Vector3 velR = Vector3(fsR.vel);
        velL.transform_to_local_frame(n, t1);
        velR.transform_to_local_frame(n, t1);
        //
        double rhoL = fsL.gas.rho;
        double pL = fsL.gas.p;
        double velxL = velL.x;
        double velyL = velL.y;
        double uL = gmodel.internal_energy(fsL.gas);
        double aL = fsL.gas.a;
        double keL = 0.5*(velxL*velxL + velyL*velyL);
        double HL = uL + pL/rhoL + keL;
        //
        double rhoR = fsR.gas.rho;
        double pR = fsR.gas.p;
        double velxR = velR.x;
        double velyR = velR.y;
        double uR = gmodel.internal_energy(fsR.gas);
        double aR = fsR.gas.a;
        double keR = 0.5*(velxR*velxR + velyR*velyR);
        double HR = uR + pR/rhoR + keR;
        //
        double am = fmax(aL, aR);
        double ML = velxL/am;
        double MR = velxR/am;
        // Left state:
        // pressure splitting (eqn 7)
        // and velocity splitting (eqn 9)
        double pLplus, velxLplus;
        if (fabs(velxL) <= aL) {
            velxLplus = 1.0/(4.0*aL) * (velxL+aL)*(velxL+aL);
            pLplus = pL*velxLplus * (1.0/aL * (2.0-velxL/aL));
        } else {
            velxLplus = 0.5*(velxL+fabs(velxL));
            pLplus = pL*velxLplus * (1.0/velxL);
        }
        // Right state:
        // pressure splitting (eqn 7)
        // and velocity splitting (eqn 9)
        double pRminus, velxRminus;
        if (fabs(velxR) <= aR) {
            velxRminus = -1.0/(4.0*aR) * (velxR-aR)*(velxR-aR);
            pRminus = pR*velxRminus * (1.0/aR * (-2.0-velxR/aR));
        } else {
            velxRminus = 0.5*(velxR-fabs(velxR));
            pRminus = pR*velxRminus * (1.0/velxR);
        }
        // The mass flux.
        double massL = velxLplus * rhoL;
        double massR = velxRminus * rhoR;
        double mass_half = massL + massR;
        // Pressure flux (eqn 8)
        double p_half = pLplus + pRminus;
        // Assemble components of the flux vector (eqn 36).
        F[cqi.mass] = massL + massR;
        Vector3 momentum = Vector3(massL*velxL + massR*velxR + p_half, massL*velyL + massR*velyR);
        momentum.transform_to_global_frame(n, t1);
        F[cqi.xMom] = momentum.x;
        F[cqi.yMom] = momentum.y;
        F[cqi.totEnergy] = massL*HL + massR*HR;
        if (cqi.n_species > 1) {
            foreach (i; 0 .. cqi.n_species) {
                F[cqi.species+i] = massL*fsL.gas.massf[i] + massR*fsR.gas.massf[i];
            }
        }
        foreach (i; 0 .. cqi.n_modes) {
            F[cqi.modes+i] = massL*fsL.gas.u_modes[i] + massR*fsR.gas.u_modes[i];
        }
        //
        bool allFinite = true;
        foreach (e; F) { if (!isFinite(e)) { allFinite = false; } }
        if (!allFinite) {
            debug { import std.stdio;  writeln("face=", this); }
            throw new Exception("At least one flux quantity is not finite.");
        }
        return;
    } // end calculate_flux_hanel()

    @nogc
    void simple_flux(FlowState2D fs, GasModel gmodel)
    // Computes the face's flux vector from a single flow state.
    // Supersonic flow is assumed.
    {
        Vector3 vel = Vector3(fs.vel);
        vel.transform_to_local_frame(n, t1);
        double rho = fs.gas.rho;
        double p = fs.gas.p;
        double u = gmodel.internal_energy(fs.gas);
        double massFlux = rho * vel.x;
        Vector3 momentum = Vector3(massFlux*vel.x+p, massFlux*vel.y);
        momentum.transform_to_global_frame(n, t1);
        F[cqi.mass] = massFlux;
        F[cqi.xMom] = momentum.x;
        F[cqi.yMom] = momentum.y;
        F[cqi.totEnergy] = massFlux * (u+p/rho+0.5*(vel.x*vel.x+vel.y*vel.y));
        if (cqi.n_species > 1) {
            foreach (i; 0 .. cqi.n_species) {
                F[cqi.species+i] = massFlux * fs.gas.massf[i];
            }
        }
        foreach (i; 0 .. cqi.n_modes) {
            F[cqi.modes+i] = massFlux * fs.gas.u_modes[i];
        }
        bool allFinite = true;
        foreach (e; F) { if (!isFinite(e)) { allFinite = false; } }
        if (!allFinite) {
            debug { import std.stdio;  writeln("face=", this); }
            throw new Exception("At least one flux quantity is not finite.");
        }
        return;
    } // end simple_flux()

    @nogc
    void interp_l2r2(ref FlowState2D fsL, ref FlowState2D fsR, GasModel gmodel, bool clipFlag=false)
    // Reconstruct flow states fsL,fsR, at the middle interface for a stencil of 4 cell-centred values.
    {
        auto fsL1 = left_cells[1].fs; auto fsL0 = left_cells[0].fs;
        auto fsR0 = right_cells[0].fs; auto fsR1 = right_cells[1].fs;
        auto gasL1 = fsL1.gas; auto gasL0 = fsL0.gas; auto gasR0 = fsR0.gas; auto gasR1 = fsR1.gas;
        auto gasL = fsL.gas; auto gasR = fsR.gas;
        // First-order reconstruction is just a copy from the nearest cell centre.
        gasL.copy_values_from(gasL0);
        gasR.copy_values_from(gasR0);
        // We will interpolate only some properties.
        interp_l2r2_scalar(gasL1.rho, gasL0.rho, gasR0.rho, gasR1.rho, gasL.rho, gasR.rho, clipFlag);
        interp_l2r2_scalar(gasL1.u, gasL0.u, gasR0.u, gasR1.u, gasL.u, gasR.u, clipFlag);
        gmodel.update_thermo_from_rhou(gasL);
        gmodel.update_sound_speed(gasL);
        gmodel.update_thermo_from_rhou(gasR);
        gmodel.update_sound_speed(gasR);
        //
        interp_l2r2_scalar(fsL1.vel.x, fsL0.vel.x, fsR0.vel.x, fsR1.vel.x, fsL.vel.x, fsR.vel.x, clipFlag);
        interp_l2r2_scalar(fsL1.vel.y, fsL0.vel.y, fsR0.vel.y, fsR1.vel.y, fsL.vel.y, fsR.vel.y, clipFlag);
        return;
    } // end interp_l2r2()

} // end class Face2D


@nogc
void interp_l2r2_scalar(double qL1, double qL0, double qR0, double qR1,
                        ref double qL, ref double qR, bool clipFlag=false)
// Reconstruct values, qL,qR, at the middle interface for a stencil of 4 cell-centred values.
// Assume equal cell widths.
{
    import nm.limiters;
    // Set up differences and limiter values.
    double delLminus = (qL0 - qL1);
    double del = (qR0 - qL0);
    double delRplus = (qR1 - qR0);
    double sL = van_albada_limit1(delLminus, del);
    double sR = van_albada_limit1(del, delRplus);
    // The actual high-order reconstruction, possibly limited.
    qL = qL0 + sL * 0.125 * (del + delLminus);
    qR = qR0 - sR * 0.125 * (delRplus + del);
    if (clipFlag) {
        // An extra limiting filter to ensure that we do not compute new extreme values.
        // This was introduced to deal with very sharp transitions in species.
        qL = clip_to_limits(qL, qL0, qR0);
        qR = clip_to_limits(qR, qL0, qR0);
    }
} // end of interp_l2r2_scalar()
