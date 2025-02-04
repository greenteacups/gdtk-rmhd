/**
 * fvinterface.d
 * Finite-volume cell-interface class, for use in the CFD codes.
 * Fluxes of conserved quantities are transported (between cells) across cell interfaces.

 * Author: Peter J. and Rowan G.
 * Version: 2014-07-17: initial cut, to explore options.
 *          2015-02-13: Keep an eye on the future of the moving_grid option.
 *          2015-05-04: keep references to adjoining cells and defining vertices.
 */

module fvinterface;

import std.stdio;

import std.conv;
import std.format;
import std.math;
import ntypes.complex;
import nm.number;

import nm.bbla;
import geom;
import gas;
import fvvertex;
import fvcell;
import flowstate;
import flowgradients;
import conservedquantities;
import globalconfig;
import lsqinterp;
import mass_diffusion;
import globaldata : SimState;

enum IndexDirection {i=0, j, k, none=666}; // Needed for StructuredGrid interpolation.

class FVInterface {
public:
    int id;
    char logical_dir; // logical index direction
    bool is_on_boundary = false;  // by default, assume not on boundary
    size_t bc_id;  // if the face is on a block boundary, which one
    size_t i_bndry; // if the face is on a block boundary, store index into the array of faces attached to bc
    bool use_wall_function_shear_and_heat_flux = false; // for use in viscous_flux_calc()
    bool in_suppress_reconstruction_zone; // if true, we no do reconstruction at this face
    bool in_suppress_viscous_stresses_zone; // if true, we have zero viscous stresses at this face
    //
    // Geometry
    IndexDirection idir;   // For StructuredGrid: in which index-direction is face pointing?
    Vector3 pos;           // position of the (approx) midpoint
    Vector3 gvel;          // grid velocity at interface, m/s
    number Ybar;           // Y-coordinate of the mid-point
    number length;         // Interface length in the x,y-plane
    number[] area;         // Area m**2 for each grid-time-level.
                           // Area per radian in axisymmetric geometry
    Vector3 n;             // Direction cosines for unit normal
    Vector3 t1;            // tangent vector 1 (aka p)
    Vector3 t2;            // tangent vector 2 (aka q)
    FVVertex[] vtx;        // references to vertices for line (2D), quadrilateral and triangular (3D) faces
    //
    // Adjoining cells.
    // These are references to either active cells or ghost cells.
    // The reference may be nil if no cell has been assigned,
    // maybe for a boundary without ghost cells.
    FVCell left_cell;      // interface normal points out of this adjoining cell
    FVCell right_cell;     // interface normal points into this adjoining cell
    // For structured grids, the structure of the grid allows us to carry
    // references for several left- and right- cells.
    FVCell[] left_cells;
    FVCell[] right_cells;
    //
    // Flow
    FlowState fs;          // Flow properties
    ConservedQuantities F; // Flux conserved quantity per unit area
    number tau_wall_x, tau_wall_y, tau_wall_z; // shear at face (used by wall-function BCs)
    number q;              // heat-flux across face (used by wall-function BCs)
    //
    // Shock-detector-related quantities.
    int[] nbr_id; // list of neighbour ids
    FlowState*[] nbr_fs; // list of neighbouring flow states
    number[] nbr_dist; // distance to neighbour
    //
    // Viscous-flux-related quantities.
    FlowGradients* grad;
    WLSQGradWorkspace* ws_grad;
    Vector3*[] cloud_pos; // Positions of flow points for gradients calculation.
    FlowState*[] cloud_fs; // References to flow states at those points.
    number[] jx; // diffusive mass flux in x
    number[] jy; // diffusive mass flux in y
    number[] jz; // diffusive mass flux in z
    number[] hs; // enthalpies for diffusive flux
    number q_diffusion;
    number q_conduction;
    //
    // Shape sensitivity calculator workspace.
    string global_id;
    version(shape_sensitivity) {
        //string global_id;
	number[][] dFdU;
        // arrays used to temporarily store data intended for the neighbouring block
        // during construction of the external portion of the flow Jacobian.
        size_t[] idList;
        number[] aa;
    }
private:
    LocalConfig myConfig;

public:
    @disable this();
    
    this(LocalConfig myConfig,
         IndexDirection idir,
         bool allocate_spatial_deriv_lsq_workspace,
         int id_init=-1,
         char dir=' ')
    {
        this.myConfig = myConfig;
        this.idir = idir;
        id = id_init;
        logical_dir = dir;
        area.length = myConfig.n_grid_time_levels;
        gvel = Vector3(0.0,0.0,0.0); // default to fixed grid
        auto gmodel = myConfig.gmodel;
        uint n_species = myConfig.n_species;
        uint n_modes = myConfig.n_modes;
        double[] T_modes; foreach(i; 0 .. n_modes) { T_modes ~= 300.0; }
        double[] turb_init;
        foreach(i; 0 .. myConfig.turb_model.nturb)
            turb_init ~= myConfig.turb_model.turb_limits(i).re;
        fs = FlowState(gmodel, 100.0e3, 300, T_modes, Vector3(0.0,0.0,0.0), turb_init);
        F = new_ConservedQuantities(myConfig.cqi.n);
        F.clear();
        grad = new FlowGradients(myConfig);
        if (allocate_spatial_deriv_lsq_workspace) {
            ws_grad = new WLSQGradWorkspace();
        }
        version(multi_species_gas) {
            jx.length = n_species;
            jy.length = n_species;
            jz.length = n_species;
            hs.length = n_species;
        }
        version(shape_sensitivity) {
            dFdU.length = 7; // number of conserved variables; FIX-ME for versions
            foreach (ref a; dFdU) a.length = 7;
            foreach (i; 0..dFdU.length) {
                foreach (j; 0..dFdU[i].length) {
                    dFdU[i][j] = 0.0;
                }
            }
        }
        q_diffusion = to!number(0.0);
        q_conduction = to!number(0.0);
    }

    this(FVInterface other, GasModel gm) // not const; see note below
    {
        id = other.id;
        idir = other.idir;
        // We are sort-of promising not to alter the myConfig object,
        // so the rest of the code had better honour that deal...
        myConfig = cast(LocalConfig)other.myConfig;
        is_on_boundary = other.is_on_boundary;
        bc_id = other.bc_id;
        use_wall_function_shear_and_heat_flux = other.use_wall_function_shear_and_heat_flux;
        pos = other.pos;
        gvel = other.gvel;
        Ybar = other.Ybar;
        length = other.length;
        area = other.area.dup;
        n = other.n;
        t1 = other.t1;
        t2 = other.t2;
        fs = FlowState(other.fs, gm);
        F = new_ConservedQuantities(other.F.length); F.copy_values_from(other.F);
        tau_wall_x = other.tau_wall_x;
        tau_wall_y = other.tau_wall_y;
        tau_wall_z = other.tau_wall_z;
        q = other.q;
        grad = new FlowGradients(*(other.grad));
        if (other.ws_grad) ws_grad = new WLSQGradWorkspace(*(other.ws_grad));
        // Because we copy the following pointers and references,
        // we cannot have const (or "in") qualifier on other.
        cloud_pos = other.cloud_pos.dup();
        cloud_fs = other.cloud_fs.dup();
        version(multi_species_gas) {
            jx = other.jx.dup();
            jy = other.jy.dup();
            jz = other.jz.dup();
            hs = other.hs.dup();
        }
        // FIX-ME - KYLE -- there's a typo here. Not sure the intent.
        version(steadystate) {
            dFdU_L.length = 5; // number of conserved variables; FIX-ME for versions
            foreach (ref a; dFdU_L) a.length = 5;
            dFdU_R.length = 5;
            foreach (ref a; dFdU_R) a.length = 5;
        }
        q_diffusion = other.q_diffusion;
    }

    @nogc
    void setLocalConfig(LocalConfig lcfg)
    {
        myConfig = lcfg;
    }
    @nogc
    void copy_values_from(in FVInterface other, uint type_of_copy)
    {
        switch (type_of_copy) {
        case CopyDataOption.minimal_flow:
        case CopyDataOption.all_flow:
            fs.copy_values_from(other.fs);
            F.copy_values_from(other.F);
            tau_wall_x = other.tau_wall_x;
            tau_wall_y = other.tau_wall_y;
            tau_wall_z = other.tau_wall_z;
            q = other.q;
            q_diffusion = other.q_diffusion;
            break;
        case CopyDataOption.grid:
            pos.set(other.pos);
            gvel.set(other.gvel);
            Ybar = other.Ybar;
            length = other.length;
            area[] = other.area[];
            n.set(other.n); t1.set(other.t1); t2.set(other.t2);
            break;
        case CopyDataOption.all:
        default:
            id = other.id;
            idir = other.idir;
            // We are sort-of promising not to alter the myConfig object,
            // so the rest of the code had better honour that deal...
            myConfig = cast(LocalConfig)other.myConfig;
            pos.set(other.pos);
            gvel.set(other.gvel);
            Ybar = other.Ybar;
            length = other.length;
            area[] = other.area[];
            n.set(other.n); t1.set(other.t1); t2.set(other.t2);
            fs.copy_values_from(other.fs);
            F.copy_values_from(other.F);
            tau_wall_x = other.tau_wall_x;
            tau_wall_y = other.tau_wall_y;
            tau_wall_z = other.tau_wall_z;
            q = other.q;
            grad.copy_values_from(*(other.grad));
            q_diffusion = other.q_diffusion;
            // omit scratch workspace ws_grad
        } // end switch
    }

    @nogc
    void copy_grid_level_to_level(uint from_level, uint to_level)
    {
        area[to_level] = area[from_level];
    }

    override string toString() const
    {
        char[] repr;
        repr ~= "FVInterface(";
        repr ~= "id=" ~ to!string(id);
        repr ~= ", idir=" ~ to!string(idir);
        repr ~= ", universe_blk_id=" ~ to!string(myConfig.universe_blk_id);
        repr ~= ", pos=" ~ to!string(pos);
        repr ~= ", vtx_ids=[";
        foreach (v; vtx) { repr ~= format("%d,", v.id); }
        repr ~= "]";
        repr ~= format(", left_cell_id=%d", left_cell ? left_cell.id : -1);
        repr ~= format(", right_cell_id=%d", right_cell ? right_cell.id : -1);
        repr ~= ", gvel=" ~ to!string(gvel);
        repr ~= ", Ybar=" ~ to!string(Ybar);
        repr ~= ", length=" ~ to!string(length);
        repr ~= ", area=" ~ to!string(area);
        repr ~= ", n=" ~ to!string(n);
        repr ~= ", t1=" ~ to!string(t1);
        repr ~= ", t2=" ~ to!string(t2);
        repr ~= ", fs=" ~ to!string(fs);
        repr ~= ", tau_wall_x=" ~ to!string(tau_wall_x);
        repr ~= ", tau_wall_y=" ~ to!string(tau_wall_y);
        repr ~= ", tau_wall_z=" ~ to!string(tau_wall_z);
        repr ~= ", q=" ~ to!string(q);
        repr ~= ", F=" ~ to!string(F);
        repr ~= ", grad=" ~ to!string(grad);
        repr ~= ", cloud_pos=[";
        // Because the positions are held as pointers to Vector3 objects,
        // we will get more interesting information by printing the objects
        // that they point to.
        foreach (i, vtxptr; cloud_pos) {
            if (i > 0) { repr ~= ", "; }
            repr ~= to!string(*vtxptr);
        }
        repr ~= "]";
        repr ~= ", cloud_fs=" ~ to!string(cloud_fs);
        repr ~= ")";
        return to!string(repr);
    }

    @nogc
    void update_2D_geometric_data(size_t gtl, bool axisymmetric)
    {
        number xA = vtx[0].pos[gtl].x;
        number yA = vtx[0].pos[gtl].y;
        number xB = vtx[1].pos[gtl].x;
        number yB = vtx[1].pos[gtl].y;
        number LAB = sqrt((xB-xA)*(xB-xA) + (yB-yA)*(yB-yA));
        // Direction cosines for the unit normal and two tangential directions.
        if (LAB > 1.0e-12) {
            // Normal is purely in the xy-plane, pointing to the "right"
            // as we sit at A, looking toward B.
            n.set((yB-yA)/LAB, -(xB-xA)/LAB, to!number(0.0));
            t2 = Vector3(0.0, 0.0, 1.0);
            cross(t1, n, t2);
            length = LAB; // Length in the XY-plane.
        } else {
            // A and B coincide.
            n = Vector3(1.0, 0.0, 0.0); // Arbitrary direction
            t2 = Vector3(0.0, 0.0, 1.0);
            t1 = Vector3(0.0, 1.0, 0.0);
            length = 0.0; // Zero length in the xy-plane
        }
        // Mid-point and surface area.
        number Xbar = 0.5*(xA+xB);
        Ybar = 0.5*(yA+yB);
        if (axisymmetric) {
            area[gtl] = length * Ybar; // Face area per radian.
        } else {
            area[gtl] = length; // Assume unit depth in the Z-direction.
        }
        pos.set(Xbar, Ybar, to!number(0.0));
    } // end update_2D_geometric_data()

    @nogc
    void update_3D_geometric_data(size_t gtl)
    {
        switch (vtx.length) {
        case 3:
            triangle_properties(vtx[0].pos[gtl], vtx[1].pos[gtl],
                                vtx[2].pos[gtl],
                                pos, n, t1, t2, area[gtl]);
            length = sqrt(area[gtl]);
            break;
        case 4:
            quad_properties(vtx[0].pos[gtl], vtx[1].pos[gtl],
                            vtx[2].pos[gtl], vtx[3].pos[gtl],
                            pos, n, t1, t2, area[gtl]);
            length = sqrt(area[gtl]);
            break;
        default:
            string msg = "FVInterface.update_3D_geometric_data(): Unhandled number of vertices: ";
            debug { msg ~= format("%d", vtx.length); }
            throw new FlowSolverException(msg);
        } // end switch
    } // end update_3D_geometric_data()

    @nogc
    number upwind_weighting(number M)
    {
        // Weighting function defined on page 78 of Ian Johnston's thesis.
        // M is Mach number in direction pointing toward the location
        // at which we are evaluating the weighted sum.
        if (M > 1.0) return to!number(1.0);
        number Mp1 = M + 1.0;
        return (Mp1 > 0.0) ? (0.25*Mp1^^2) : to!number(0.0);
    }

    @nogc
    void average_vertex_deriv_values()
    {
        number[4] uwfs;
        number uwf_sum = 0.0;
        if (myConfig.upwind_vertex_gradients) {
            // Upwind weighting of the gradient values.
            if (!left_cell && !right_cell) {
                throw new Exception("Oops! This face does not have at least one cell attached.");
            }
            FVCell c = (right_cell && right_cell.is_interior_to_domain) ? right_cell : left_cell;
            Vector3 tangent;
            foreach (i; 0 .. vtx.length) {
                tangent.set(pos); tangent -= vtx[i].pos[0]; tangent.normalize();
                number M = c.fs.vel.dot(tangent)/c.fs.gas.a;
                number uwf = upwind_weighting(M);
                uwfs[i] = uwf;
                uwf_sum += uwf;
            }
        } else {
            // Equal weighting of the gradient values.
            foreach (i; 0 .. vtx.length) {
                uwfs[i] = 1.0;
                uwf_sum += 1.0;
            }
        }
        grad.copy_values_from(*(vtx[0].grad));
        grad.scale_values_by(uwfs[0]);
        foreach (i; 1 .. vtx.length) {
            grad.accumulate_values_from(*(vtx[i].grad), uwfs[i]);
        }
        grad.scale_values_by(1.0/uwf_sum);
    } // end average_vertex_deriv_values()

    @nogc
    void average_cell_deriv_values(int gtl)
    {
        if (!left_cell && !right_cell) {
            throw new Exception("Oops! This face does not have at least one cell attached.");
        }

        bool one_interior_cell_exists = false;
        if ( (left_cell && !right_cell) ||
             (!left_cell && right_cell) ) {
            one_interior_cell_exists = true;
        } else { // both a left cell and right cell exists => check if they are interior cells
            if ( (left_cell.is_interior_to_domain && !right_cell.is_interior_to_domain) ||
                 (!left_cell.is_interior_to_domain && right_cell.is_interior_to_domain) ) {
                one_interior_cell_exists = true;
            }
        }

        if (one_interior_cell_exists) {
            // The interface has only one cell interior to the domain and
            // that doesn't have a mapping to a cell in a neighbouring block.
            // This means that the interface is along a domain boundary.
            // We just copy the gradient from the interior-cell to the interface.
            FVCell c = (right_cell && right_cell.is_interior_to_domain) ? right_cell : left_cell;
            // vel-x
            grad.vel[0][0] = c.grad.vel[0][0];
            grad.vel[0][1] = c.grad.vel[0][1];
            grad.vel[0][2] = c.grad.vel[0][2];
            // vel-y
            grad.vel[1][0] = c.grad.vel[1][0];
            grad.vel[1][1] = c.grad.vel[1][1];
            grad.vel[1][2] = c.grad.vel[1][2];
            // vel-z
            grad.vel[2][0] = c.grad.vel[2][0];
            grad.vel[2][1] = c.grad.vel[2][1];
            grad.vel[2][2] = c.grad.vel[2][2];
            // massf
            version(multi_species_gas) {
                foreach (isp; 0 .. myConfig.n_species) {
                    grad.massf[isp][0] = c.grad.massf[isp][0];
                    grad.massf[isp][1] = c.grad.massf[isp][1];
                    grad.massf[isp][2] = c.grad.massf[isp][2];
                }
            }
            // T
            grad.T[0] = c.grad.T[0];
            grad.T[1] = c.grad.T[1];
            grad.T[2] = c.grad.T[2];
            // thermal modes
            version(multi_T_gas) {
                uint n_modes = myConfig.n_modes;
                foreach (imode; 0 .. n_modes) {
                    grad.T_modes[imode][0] = c.grad.T_modes[imode][0];
                    grad.T_modes[imode][1] = c.grad.T_modes[imode][1];
                    grad.T_modes[imode][2] = c.grad.T_modes[imode][2];
                }
            }
            version(turbulence) {
                foreach(i; 0 .. myConfig.turb_model.nturb) {
                    grad.turb[i][0] = c.grad.turb[i][0];
                    grad.turb[i][1] = c.grad.turb[i][1];
                    grad.turb[i][2] = c.grad.turb[i][2];
                }
            }
            // MHD
            version(MHD) {
                // vel-B
                grad.B[0][0] = c.grad.B[0][0];
                grad.B[0][1] = c.grad.B[0][1];
                grad.B[0][2] = c.grad.B[0][2];
                // vel-B
                grad.B[1][0] = c.grad.B[1][0];
                grad.B[1][1] = c.grad.B[1][1];
                grad.B[1][2] = c.grad.B[1][2];
                // vel-B
                grad.B[2][0] = c.grad.B[2][0];
                grad.B[2][1] = c.grad.B[2][1];
                grad.B[2][2] = c.grad.B[2][2];
            }
        } else {
            // With two attached cells, we are at a face that is internal to the domain
            // and so we can proceed to compute the average of the gradient values.
            number qL; number qR;
            FVCell cL0 = left_cell; // i
            FVCell cR0 = right_cell; // j
            // interface normal
            number nx = n.x;
            number ny = n.y;
            number nz = n.z;
            // vector from left-cell-centre to face midpoint
            number rLx = pos.x - cL0.pos[gtl].x;
            number rLy = pos.y - cL0.pos[gtl].y;
            number rLz = pos.z - cL0.pos[gtl].z;
            number rRx = pos.x - cR0.pos[gtl].x;
            number rRy = pos.y - cR0.pos[gtl].y;
            number rRz = pos.z - cR0.pos[gtl].z;
            // vector from left-cell-centre to right-cell-centre
            number ex = cR0.pos[gtl].x - cL0.pos[gtl].x;
            number ey = cR0.pos[gtl].y - cL0.pos[gtl].y;
            number ez = cR0.pos[gtl].z - cL0.pos[gtl].z;
            // ehat
            number emag = sqrt(ex*ex + ey*ey + ez*ez);
            number ehatx = ex/emag;
            number ehaty = ey/emag;
            number ehatz = ez/emag;
            // ndotehat
            number ndotehat = nx*ehatx + ny*ehaty + nz*ehatz;
            number avgdotehat;
            number jump;
            // vel-x
            avgdotehat = 0.5*(cL0.grad.vel[0][0]+cR0.grad.vel[0][0])*ehatx +
                0.5*(cL0.grad.vel[0][1]+cR0.grad.vel[0][1])*ehaty +
                0.5*(cL0.grad.vel[0][2]+cR0.grad.vel[0][2])*ehatz;
            jump = avgdotehat - (cR0.fs.vel.x - cL0.fs.vel.x)/emag;
            grad.vel[0][0] = 0.5*(cL0.grad.vel[0][0]+cR0.grad.vel[0][0]) - jump*(nx/ndotehat);
            grad.vel[0][1] = 0.5*(cL0.grad.vel[0][1]+cR0.grad.vel[0][1]) - jump*(ny/ndotehat);
            grad.vel[0][2] = 0.5*(cL0.grad.vel[0][2]+cR0.grad.vel[0][2]) - jump*(nz/ndotehat);
            // vel-y
            avgdotehat = 0.5*(cL0.grad.vel[1][0]+cR0.grad.vel[1][0])*ehatx +
                0.5*(cL0.grad.vel[1][1]+cR0.grad.vel[1][1])*ehaty +
                0.5*(cL0.grad.vel[1][2]+cR0.grad.vel[1][2])*ehatz;
            jump = avgdotehat - (cR0.fs.vel.y - cL0.fs.vel.y)/emag;
            grad.vel[1][0] = 0.5*(cL0.grad.vel[1][0]+cR0.grad.vel[1][0]) - jump*(nx/ndotehat);
            grad.vel[1][1] = 0.5*(cL0.grad.vel[1][1]+cR0.grad.vel[1][1]) - jump*(ny/ndotehat);
            grad.vel[1][2] = 0.5*(cL0.grad.vel[1][2]+cR0.grad.vel[1][2]) - jump*(nz/ndotehat);
            // vel-z
            avgdotehat = 0.5*(cL0.grad.vel[2][0]+cR0.grad.vel[2][0])*ehatx +
                0.5*(cL0.grad.vel[2][1]+cR0.grad.vel[2][1])*ehaty +
                0.5*(cL0.grad.vel[2][2]+cR0.grad.vel[2][2])*ehatz;
            jump = avgdotehat - (cR0.fs.vel.z - cL0.fs.vel.z)/emag;
            grad.vel[2][0] = 0.5*(cL0.grad.vel[2][0]+cR0.grad.vel[2][0]) - jump*(nx/ndotehat);
            grad.vel[2][1] = 0.5*(cL0.grad.vel[2][1]+cR0.grad.vel[2][1]) - jump*(ny/ndotehat);
            grad.vel[2][2] = 0.5*(cL0.grad.vel[2][2]+cR0.grad.vel[2][2]) - jump*(nz/ndotehat);
            // massf
            version(multi_species_gas) {
                foreach (isp; 0 .. myConfig.n_species) {
                    avgdotehat = 0.5*(cL0.grad.massf[isp][0]+cR0.grad.massf[isp][0])*ehatx +
                        0.5*(cL0.grad.massf[isp][1]+cR0.grad.massf[isp][1])*ehaty +
                        0.5*(cL0.grad.massf[isp][2]+cR0.grad.massf[isp][2])*ehatz;
                    jump = avgdotehat - (cR0.fs.gas.massf[isp] - cL0.fs.gas.massf[isp])/emag;
                    grad.massf[isp][0] = 0.5*(cL0.grad.massf[isp][0]+cR0.grad.massf[isp][0]) - jump*(nx/ndotehat);
                    grad.massf[isp][1] = 0.5*(cL0.grad.massf[isp][1]+cR0.grad.massf[isp][1]) - jump*(ny/ndotehat);
                    grad.massf[isp][2] = 0.5*(cL0.grad.massf[isp][2]+cR0.grad.massf[isp][2]) - jump*(nz/ndotehat);
                }
            }
            // T
            avgdotehat = 0.5*(cL0.grad.T[0]+cR0.grad.T[0])*ehatx +
                0.5*(cL0.grad.T[1]+cR0.grad.T[1])*ehaty +
                0.5*(cL0.grad.T[2]+cR0.grad.T[2])*ehatz;
            jump = avgdotehat - (cR0.fs.gas.T - cL0.fs.gas.T)/emag;
            grad.T[0] = 0.5*(cL0.grad.T[0]+cR0.grad.T[0]) - jump*(nx/ndotehat);
            grad.T[1] = 0.5*(cL0.grad.T[1]+cR0.grad.T[1]) - jump*(ny/ndotehat);
            grad.T[2] = 0.5*(cL0.grad.T[2]+cR0.grad.T[2]) - jump*(nz/ndotehat);
            version(multi_T_gas) {
                uint n_modes = myConfig.n_modes;
                foreach (imode; 0 .. n_modes) {
                    avgdotehat = 0.5*(cL0.grad.T_modes[imode][0]+cR0.grad.T_modes[imode][0])*ehatx +
                        0.5*(cL0.grad.T_modes[imode][1]+cR0.grad.T_modes[imode][1])*ehaty +
                        0.5*(cL0.grad.T_modes[imode][2]+cR0.grad.T_modes[imode][2])*ehatz;
                    jump = avgdotehat - (cR0.fs.gas.T_modes[imode] - cL0.fs.gas.T_modes[imode])/emag;
                    grad.T_modes[imode][0] = 0.5*(cL0.grad.T_modes[imode][0]+cR0.grad.T_modes[imode][0]) - jump*(nx/ndotehat);
                    grad.T_modes[imode][1] = 0.5*(cL0.grad.T_modes[imode][1]+cR0.grad.T_modes[imode][1]) - jump*(ny/ndotehat);
                    grad.T_modes[imode][2] = 0.5*(cL0.grad.T_modes[imode][2]+cR0.grad.T_modes[imode][2]) - jump*(nz/ndotehat);
                }
            }
            version(turbulence) {
                foreach(i; 0 .. myConfig.turb_model.nturb) {
                    avgdotehat = 0.5*(cL0.grad.turb[i][0]+cR0.grad.turb[i][0])*ehatx +
                        0.5*(cL0.grad.turb[i][1]+cR0.grad.turb[i][1])*ehaty +
                        0.5*(cL0.grad.turb[i][2]+cR0.grad.turb[i][2])*ehatz;
                    jump = avgdotehat - (cR0.fs.turb[i] - cL0.fs.turb[i])/emag;
                    grad.turb[i][0] = 0.5*(cL0.grad.turb[i][0]+cR0.grad.turb[i][0]) - jump*(nx/ndotehat);
                    grad.turb[i][1] = 0.5*(cL0.grad.turb[i][1]+cR0.grad.turb[i][1]) - jump*(ny/ndotehat);
                    grad.turb[i][2] = 0.5*(cL0.grad.turb[i][2]+cR0.grad.turb[i][2]) - jump*(nz/ndotehat);
                }
            }
            // MHD
            version(MHD) {
                // B-x
                avgdotehat = 0.5*(cL0.grad.B[0][0]+cR0.grad.B[0][0])*ehatx +
                    0.5*(cL0.grad.B[0][1]+cR0.grad.B[0][1])*ehaty +
                    0.5*(cL0.grad.B[0][2]+cR0.grad.B[0][2])*ehatz;
                jump = avgdotehat - (cR0.fs.B.x - cL0.fs.B.x)/emag;
                grad.B[0][0] = 0.5*(cL0.grad.B[0][0]+cR0.grad.B[0][0]) - jump*(nx/ndotehat);
                grad.B[0][1] = 0.5*(cL0.grad.B[0][1]+cR0.grad.B[0][1]) - jump*(ny/ndotehat);
                grad.B[0][2] = 0.5*(cL0.grad.B[0][2]+cR0.grad.B[0][2]) - jump*(nz/ndotehat);
                // B-y
                avgdotehat = 0.5*(cL0.grad.B[1][0]+cR0.grad.B[1][0])*ehatx +
                    0.5*(cL0.grad.B[1][1]+cR0.grad.B[1][1])*ehaty +
                    0.5*(cL0.grad.B[1][2]+cR0.grad.B[1][2])*ehatz;
                jump = avgdotehat - (cR0.fs.B.y - cL0.fs.B.y)/emag;
                grad.B[1][0] = 0.5*(cL0.grad.B[1][0]+cR0.grad.B[1][0]) - jump*(nx/ndotehat);
                grad.B[1][1] = 0.5*(cL0.grad.B[1][1]+cR0.grad.B[1][1]) - jump*(ny/ndotehat);
                grad.B[1][2] = 0.5*(cL0.grad.B[1][2]+cR0.grad.B[1][2]) - jump*(nz/ndotehat);
                // B-z
                avgdotehat = 0.5*(cL0.grad.B[2][0]+cR0.grad.B[2][0])*ehatx +
                    0.5*(cL0.grad.B[2][1]+cR0.grad.B[2][1])*ehaty +
                    0.5*(cL0.grad.B[2][2]+cR0.grad.B[2][2])*ehatz;
                jump = avgdotehat - (cR0.fs.B.z - cL0.fs.B.z)/emag;
                grad.B[2][0] = 0.5*(cL0.grad.B[2][0]+cR0.grad.B[2][0]) - jump*(nx/ndotehat);
                grad.B[2][1] = 0.5*(cL0.grad.B[2][1]+cR0.grad.B[2][1]) - jump*(ny/ndotehat);
                grad.B[2][2] = 0.5*(cL0.grad.B[2][2]+cR0.grad.B[2][2]) - jump*(nz/ndotehat);
            }
        }
    } // end average_cell_spatial_derivs()

    @nogc
    void average_turbulent_transprops()
    {
        if (left_cell && right_cell && left_cell.is_interior_to_domain && right_cell.is_interior_to_domain) {
            fs.k_t = 0.5*(left_cell.fs.k_t+right_cell.fs.k_t);
            fs.mu_t = 0.5*(left_cell.fs.mu_t+right_cell.fs.mu_t);
        } else if (left_cell && left_cell.is_interior_to_domain) {
            fs.k_t = left_cell.fs.k_t;
            fs.mu_t = left_cell.fs.mu_t;
        } else if (right_cell && right_cell.is_interior_to_domain) {
            fs.k_t = right_cell.fs.k_t;
            fs.mu_t = right_cell.fs.mu_t;
        } else {
            assert(0, "Oops, don't seem to have a cell available.");
        }
    }

    @nogc
    void viscous_flux_calc()
    // Unified 2D and 3D viscous-flux calculation.
    // Note that the gradient values need to be in place before calling this procedure.
    // Note, also, that the viscous fluxes are added to the flux-vector components.
    {
        if (in_suppress_viscous_stresses_zone) {
            // We wish to ignore the viscous fluxes here.
            return;
        }
        auto gmodel = myConfig.gmodel;
        uint n_species = myConfig.n_species;
        uint n_modes = myConfig.n_modes;
        double viscous_factor = myConfig.viscous_factor;
        number k_eff = fs.gas.k + fs.k_t ;
        number mu_eff = fs.gas.mu + fs.mu_t;
        number lmbda;
        lmbda = -2.0/3.0 * mu_eff;

        number local_pressure = fs.gas.p;
        number shear_stress_limit = myConfig.shear_stress_relative_limit * local_pressure;
        number heat_transfer_limit = (mu_eff > 0.0) ? k_eff/mu_eff*shear_stress_limit : to!number(0.0);

        // Species diffusion: Changed by NNG on 22/01/18.
        // We now apply both laminar and turbulent diffusion additively, to prevent artificially low
        // diffusion in areas with a small turbulent viscosity.
        version(multi_species_gas) {
            if (myConfig.mass_diffusion_model != MassDiffusionModel.none) {
                myConfig.massDiffusion.update_mass_fluxes(fs, *grad, jx, jy, jz);
                foreach (isp; 0 .. n_species) {
                    jx[isp] *= viscous_factor;
                    jy[isp] *= viscous_factor;
                    jz[isp] *= viscous_factor;
                }
            } else if (myConfig.turb_model.isTurbulent) { // Turbulent but no mass diffusion model
                foreach (isp; 0 .. n_species) {
                    jx[isp] = to!number(0.0);
                    jy[isp] = to!number(0.0);
                    jz[isp] = to!number(0.0);
                }
            }
        }

        if (myConfig.turb_model.isTurbulent) {
            double Sc_t = myConfig.turbulence_schmidt_number;
            number D_t = fs.mu_t / (fs.gas.rho * Sc_t);
            version(multi_species_gas) {
                foreach (isp; 0 .. n_species) {
                    jx[isp] -= fs.gas.rho * D_t * grad.massf[isp][0];
                    jy[isp] -= fs.gas.rho * D_t * grad.massf[isp][1];
                    jz[isp] -= fs.gas.rho * D_t * grad.massf[isp][2];
                }
            }
        }
        number tau_xx = 0.0;
        number tau_yy = 0.0;
        number tau_zz = 0.0;
        number tau_xy = 0.0;
        number tau_xz = 0.0;
        number tau_yz = 0.0;
        if (myConfig.dimensions == 3) {
            number dudx = grad.vel[0][0];
            number dudy = grad.vel[0][1];
            number dudz = grad.vel[0][2];
            number dvdx = grad.vel[1][0];
            number dvdy = grad.vel[1][1];
            number dvdz = grad.vel[1][2];
            number dwdx = grad.vel[2][0];
            number dwdy = grad.vel[2][1];
            number dwdz = grad.vel[2][2];
            // 3-dimensional planar stresses.
            tau_xx = 2.0*mu_eff*dudx + lmbda*(dudx + dvdy + dwdz);
            tau_yy = 2.0*mu_eff*dvdy + lmbda*(dudx + dvdy + dwdz);
            tau_zz = 2.0*mu_eff*dwdz + lmbda*(dudx + dvdy + dwdz);
            tau_xy = mu_eff * (dudy + dvdx);
            tau_xz = mu_eff * (dudz + dwdx);
            tau_yz = mu_eff * (dvdz + dwdy);
        } else {
            // 2D
            number dudx = grad.vel[0][0];
            number dudy = grad.vel[0][1];
            number dvdx = grad.vel[1][0];
            number dvdy = grad.vel[1][1];
            if (myConfig.axisymmetric) {
                // Viscous stresses at the mid-point of the interface.
                // Axisymmetric terms no longer include the radial multiplier
                // as that has been absorbed into the interface area calculation.
                number ybar = Ybar;
                if (ybar > 1.0e-10) { // something very small for a cell height
                    tau_xx = 2.0 * mu_eff * dudx + lmbda * (dudx + dvdy + fs.vel.y / ybar);
                    tau_yy = 2.0 * mu_eff * dvdy + lmbda * (dudx + dvdy + fs.vel.y / ybar);
                } else {
                    tau_xx = 0.0;
                    tau_yy = 0.0;
                }
                tau_xy = mu_eff * (dudy + dvdx);
            } else {
                // 2-dimensional-planar stresses.
                tau_xx = 2.0 * mu_eff * dudx + lmbda * (dudx + dvdy);
                tau_yy = 2.0 * mu_eff * dvdy + lmbda * (dudx + dvdy);
                tau_xy = mu_eff * (dudy + dvdx);
            }
        }
        // Thermal conductivity (NOTE: q is total energy flux)
        number qx = k_eff * grad.T[0];
        number qy = k_eff * grad.T[1];
        number qz = k_eff * grad.T[2];
        version(multi_T_gas) {
            foreach (imode; 0 .. n_modes) {
                qx += viscous_factor * fs.gas.k_modes[imode] * grad.T_modes[imode][0];
                qy += viscous_factor * fs.gas.k_modes[imode] * grad.T_modes[imode][1];
                qz += viscous_factor * fs.gas.k_modes[imode] * grad.T_modes[imode][2];
            }
        }
        q_conduction = (qx*n.x + qy*n.y + qz*n.z);
        version(multi_species_gas) {
            if (myConfig.turb_model.isTurbulent ||
                myConfig.mass_diffusion_model != MassDiffusionModel.none ) {
                q_diffusion = to!number(0.0);
                gmodel.enthalpies(fs.gas, hs);
                foreach (isp; 0 .. n_species) {
                    qx -= jx[isp] * hs[isp];
                    qy -= jy[isp] * hs[isp];
                    qz -= jz[isp] * hs[isp];
                    q_diffusion -= (jx[isp]*hs[isp]*n.x + jy[isp]*hs[isp]*n.y + jz[isp]*hs[isp]*n.z);
                }
            }
        }
        version(turbulence) {
            if ( myConfig.turb_model.isTurbulent &&
                 !(myConfig.axisymmetric && (Ybar <= 1.0e-10)) ) {
                // Turbulence contribution to the shear stresses.
                number tke = myConfig.turb_model.turbulent_kinetic_energy(fs);
                tau_xx -= 2.0/3.0 * fs.gas.rho * tke;
                tau_yy -= 2.0/3.0 * fs.gas.rho * tke;
                if (myConfig.dimensions == 3) { tau_zz -= 2.0/3.0 * fs.gas.rho * tke; }

                // Turbulent transport of turbulent kinetic energy
                number[3] qtke = myConfig.turb_model.turbulent_kinetic_energy_transport(fs, *grad);
                qx += qtke[0];
                qy += qtke[1];
                if (myConfig.dimensions == 3) { qz += qtke[2]; }
            }
        }
        if (myConfig.apply_shear_stress_relative_limit) {
            version(complex_numbers) {
                // Do not try to limit the component values.
                // Something in this limiting plays havoc with the complex derivatives.
            } else {
                // Apply limits to the component values.
                tau_xx = copysign(fmin(fabs(tau_xx),shear_stress_limit), tau_xx);
                tau_yy = copysign(fmin(fabs(tau_yy),shear_stress_limit), tau_yy);
                tau_zz = copysign(fmin(fabs(tau_zz),shear_stress_limit), tau_zz);
                tau_xy = copysign(fmin(fabs(tau_xy),shear_stress_limit), tau_xy);
                tau_xz = copysign(fmin(fabs(tau_xz),shear_stress_limit), tau_xz);
                tau_yz = copysign(fmin(fabs(tau_yz),shear_stress_limit), tau_yz);
                qx = copysign(fmin(fabs(qx),heat_transfer_limit), qx);
                qy = copysign(fmin(fabs(qy),heat_transfer_limit), qy);
                qz = copysign(fmin(fabs(qz),heat_transfer_limit), qz);
            }
        } // end if apply_shear_stress_relative_limit
        //
        // Combine into fluxes: store as the dot product (F.n).
        number nx = n.x;
        number ny = n.y;
        number nz = n.z;
        auto cqi = myConfig.cqi;
        // In some cases, the shear and heat fluxes have been previously
        // computed by the wall functions in the boundary condition call.
        if (use_wall_function_shear_and_heat_flux) {
            // Mass flux -- NO CONTRIBUTION, unless there's diffusion (below)
            // [TODO] As per Jason's recommendation, we need to do something
            // to correct for corner cells.
            // [TODO] Currently implemented for 2D; need to extend to 3D.
            F[cqi.xMom] -= tau_xx*nx + tau_wall_x;
            F[cqi.yMom] -= tau_yy*ny + tau_wall_y;
            if (cqi.threeD) { F[cqi.zMom] -= tau_zz*nz + tau_wall_z; }
            F[cqi.totEnergy] -=
                tau_xx*fs.vel.x*nx + tau_yy*fs.vel.y*ny + tau_zz*fs.vel.z*nz +
                tau_wall_x*fs.vel.x + tau_wall_y*fs.vel.y + tau_wall_z*fs.vel.z + q;
        }
        else { // proceed with locally computed shear and heat flux
            // Mass flux -- NO CONTRIBUTION, unless there's diffusion (below)
            F[cqi.xMom] -= tau_xx*nx + tau_xy*ny + tau_xz*nz;
            F[cqi.yMom] -= tau_xy*nx + tau_yy*ny + tau_yz*nz;
            if (cqi.threeD) { F[cqi.zMom] -= tau_xz*nx + tau_yz*ny + tau_zz*nz; }
            F[cqi.totEnergy] -=
                (tau_xx*fs.vel.x + tau_xy*fs.vel.y + tau_xz*fs.vel.z + qx)*nx +
                (tau_xy*fs.vel.x + tau_yy*fs.vel.y + tau_yz*fs.vel.z + qy)*ny +
                (tau_xz*fs.vel.x + tau_yz*fs.vel.y + tau_zz*fs.vel.z + qz)*nz;
        } // end if
        version(multi_T_gas) {
            foreach (imode; 0 .. n_modes) {
                F[cqi.modes+imode] -= viscous_factor * fs.gas.k_modes[imode] * grad.T_modes[imode][0] * nx;
                F[cqi.modes+imode] -= viscous_factor * fs.gas.k_modes[imode] * grad.T_modes[imode][1] * ny;
                F[cqi.modes+imode] -= viscous_factor * fs.gas.k_modes[imode] * grad.T_modes[imode][2] * nz;
                // Species diffusion contribution to the energy modes (added by NNG, 2022/01/26)
                version(multi_species_gas) {
                    if (myConfig.turb_model.isTurbulent || (myConfig.mass_diffusion_model != MassDiffusionModel.none)) {
                        foreach (isp; 0 .. n_species) {
                            number hMode = gmodel.enthalpyPerSpeciesInMode(fs.gas, cast(int)isp, cast(int)imode);
                            // The sign here needs to be opposite to the thermal conduction, hence +=
                            F[cqi.modes+imode] += viscous_factor * hMode *(jx[isp]*n.x
                                                                             + jy[isp]*n.y
                                                                             + jz[isp]*n.z);
                        }
                    }
                }
            }
        }
        version(turbulence) {
            if ( myConfig.turb_model.isTurbulent &&
                 !(myConfig.axisymmetric && (Ybar <= 1.0e-10)) ) {
                //
                // Turbulence transport of the turbulence properties themselves.
                foreach(i; 0 .. myConfig.turb_model.nturb){
                    number tau_tx = 0.0;
                    number tau_ty = 0.0;
                    number tau_tz = 0.0;
                    //
                    number mu_effective = myConfig.turb_model.viscous_transport_coeff(fs, i);
                    // Apply a limit on mu_effective in the same manner as that applied to mu_t.
                    mu_effective = fmin(mu_effective, myConfig.max_mu_t_factor * fs.gas.mu);
                    tau_tx = mu_effective * grad.turb[i][0];
                    tau_ty = mu_effective * grad.turb[i][1];
                    if (myConfig.dimensions == 3) { tau_tz = mu_effective * grad.turb[i][2]; }
                    //
                    F[cqi.rhoturb+i] -= tau_tx * nx + tau_ty * ny + tau_tz * nz;
                }
            }
        }
        version(multi_species_gas) {
            if (myConfig.turb_model.isTurbulent ||
                myConfig.mass_diffusion_model != MassDiffusionModel.none) {
                if (cqi.n_species > 1) {
                    foreach (isp; 0 .. cqi.n_species) {
                        F[cqi.species+isp] += jx[isp]*nx + jy[isp]*ny + jz[isp]*nz;
                    }
                }
            }
        }
    } // end viscous_flux_calc()

@nogc
    void resistive_MHD_flux_calc()
    // Diffusive flux terms from "An adaptive mesh semi-implicit-conservative unsplit method
    // for resistive MHD" by R. Samtaney (2005)
    //
    // Implemented by Sebastiaan van Oeveren - 11/08/23
    {
        // Conductivity:
        // Calculate electron number density (n_e) and electron mole fraction (M_e)
        auto gmodel = myConfig.gmodel;
        number massf_O = 0.0;
        number massf_O2 = 0.0;
        number massf_N2 = 0.0;
        number massf_N = 0.0;
        number massf_NO = 0.0;
        number massf_NOp = 0.0;
        number massf_Np = 0.0;
        number massf_Op = 0.0;
        number massf_N2p = 0.0;
        number massf_O2p = 0.0;
        number massf_e_minus = 0.0;

        int electron_index;
        foreach(it; 0 .. myConfig.gmodel.n_species)
        {
            if (gmodel.species_name(it) == "O") { massf_O = fs.gas.massf[it];}
            if (gmodel.species_name(it) == "O2") { massf_O2 = fs.gas.massf[it];}
            if (gmodel.species_name(it) == "N2") { massf_N2 = fs.gas.massf[it];}
            if (gmodel.species_name(it) == "N") { massf_N = fs.gas.massf[it];}
            if (gmodel.species_name(it) == "NO") { massf_NO = fs.gas.massf[it];}
            if (gmodel.species_name(it) == "NO+") { massf_NOp = fs.gas.massf[it];}
            if (gmodel.species_name(it) == "N+") { massf_Np = fs.gas.massf[it];}
            if (gmodel.species_name(it) == "O+") { massf_Op = fs.gas.massf[it];}
            if (gmodel.species_name(it) == "N2+") { massf_N2p = fs.gas.massf[it];}
            if (gmodel.species_name(it) == "O2+") { massf_O2p = fs.gas.massf[it];}
            if (gmodel.species_name(it) == "e-") { massf_e_minus = fs.gas.massf[it];}
        }

        number mmasse = 5.485799e-4;
        number mmassO = 15.999;
        number mmassO2 = 31.999;
        number mmassN2 = 28.0134;
        number mmassN = 14.0067;
        number mmassNO = 30.01;
        number mmassNOp = 30.01 + mmasse;
        number mmassNp = 14.0067 + mmasse;
        number mmassOp = 15.999 + mmasse;
        number mmassN2p = 28.0134 + mmasse;
        number mmassO2p = 31.999 + mmasse;

        number mole_O = massf_O/mmassO;
        number mole_O2 = massf_O2/mmassO2;
        number mole_N2 = massf_N2/mmassN2;
        number mole_N = massf_N/mmassN;
        number mole_NO = massf_NO/mmassNO;
        number mole_NOp = massf_NOp/mmassNOp;
        number mole_Np = massf_Np/mmassNp;
        number mole_Op = massf_Op/mmassOp;
        number mole_N2p = massf_N2p/mmassN2p;
        number mole_O2p = massf_O2p/mmassO2p;
        number mole_e = massf_e_minus/mmasse;

        number mole_sum = mole_O + mole_O2 + mole_N2 + mole_N + mole_NO + mole_NOp + mole_Np + mole_Op + mole_N2p + mole_O2p + mole_e;
        number molef_e = mole_e / mole_sum;

        number rho = fs.gas.rho;
        number T = fs.gas.T;
        number P = fs.gas.p;
        number Na = 6.02214076e23; // Avogradro's Number (1/mol)
        number We = 5.485799e-7; // Electron molar mass (kg/mol)
        number n_e = Na*massf_e_minus*rho/We;

        // Electrical conductivity: sigma
        number sigma = 1.0;
        number K_to_eV = 11604.525;  //conversion between Kelvin and eV  --K eV-1
        number Te = T / K_to_eV;

        if (molef_e <= 1.0e-4) { // Weakly Ionised Condition
            sigma = 2.82e-4 * (n_e * 1.0e-6) / (3.9 * 1.0e9 * (P / 133.322)) * 1.0e2;

        } else if (molef_e >= 1.0e-3) { // Strongly Ionised Condition
            // Calculate lnA based on Raizer's formula for strongly ionized plasma
            number lnA = 13.57 + 1.5 * log10(Te) - 0.5 * log10((n_e + 1.0) * 1.0e-6);

            // Calculate electrical conductivity using the formula from Raizer
            sigma = (1.9e2 * pow(Te, 1.5) / lnA) * 100.0; // Conductivity in Ohm-1 m-1

        } else { // Intermediate ionisation condition
            number sigmaw = 2.82e-4 * (n_e * 1.0e-6) / (3.9 * 1.0e9 * (P / 133.322)) * 1.0e2;
            number lnA = 13.57 + 1.5 * log10(Te) - 0.5 * log10((n_e + 1.0) * 1.0e-6);
            number sigmas = (1.9e2 * pow(Te, 1.5) / lnA) * 100.0;

            sigma = sigmaw + (molef_e - 1.0e-4) * (sigmas - sigmaw) / (1.0e-3 - 1.0e-4);
        }

        // Truncate extreme values - Need to verify when this is necessary
        if(sigma < 100.0) {sigma = 100.0;}
        if(sigma > 1.0e4) {sigma = 1.0e4;}

        number mu0 = 4 * std.math.PI * 1e-7;    // Permeability of free space

        // Cell-based conductivity scaling for constant magnetic Reynolds number
        number L = 1.0; // Characterisitc length scale
        number Rem = 1.0; // Magnetic Reynolds Number
        number u0 = sqrt(fs.vel.x^^2 + fs.vel.y^^2); // Velocity
        sigma = 1000.0; //Rem/(mu0*u0*L);

        // Calculate Diffusive Flux Terms:
        number eta = 1/(sigma*mu0);     // Diffusivity

        number dBxdx = grad.B[0][0] ;
        number dBxdy = grad.B[0][1] ;
        number dBydx = grad.B[1][0] ;
        number dBydy = grad.B[1][1] ;

        // Temporary Brin Test Case Boundary Condition - Ideal conducting walls
        //if(pos.y > 6.35 || pos.y < -6.35) {dBxdy = 0.0; fs.B.y = 0.0;}

        // Calculate diffusion terms
        // Divergence RMHD equations
        //number Bxdiffusion = eta * (dBxdy*n.y - dBydy*n.x);
        //number Bydiffusion = eta * (dBydx*n.x - dBxdx*n.y);
        //number ediffusion = eta * 1/mu0 * (fs.B.y*(dBydx - dBxdy)*n.x -  fs.B.x*(dBydx - dBxdy)*n.y);

        // Divergence-free RMHD equations
        number Bxdiffusion = eta * (dBxdx*n.x + dBxdy*n.y);
        number Bydiffusion = eta * (dBydx*n.x + dBydy*n.y);

        number ediffusion = eta * 1/mu0 * (fs.B.y*(dBydx - dBxdy)*n.x -  fs.B.x*(dBydx - dBxdy)*n.y);

        auto cqi = myConfig.cqi;
        F[cqi.xB] -= Bxdiffusion;
        F[cqi.yB] -= Bydiffusion;
        //F[cqi.totEnergy] -= ediffusion;
    }


} // end of class FV_Interface
