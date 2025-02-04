// internal_copy_then_reflect.d

module bc.ghost_cell_effect.internal_copy_then_reflect;

import std.json;
import std.string;
import std.conv;
import std.stdio;
import std.math;

import geom;
import globalconfig;
import globaldata;
import flowstate;
import fvinterface;
import fvcell;
import fluidblock;
import sfluidblock;
import gas;
import bc;


class GhostCellInternalCopyThenReflect : GhostCellEffect {
public:

    this(int id, int boundary)
    {
        super(id, boundary, "InternalCopyThenReflect");
    }

    override string toString() const
    {
        return "InternalCopyThenReflect()";
    }

    @nogc
    override void apply_for_interface_unstructured_grid(double t, int gtl, int ftl, FVInterface f)
    {
        // In contrast with the structured-grid implementation, below,
        // we use a single source cell because we're not sure that
        // the next cell in the interior list (if there is one) will
        // be positioned as a mirror image of the second ghost cell.
        // If the grid is clustered toward the boundary, the error
        // introduced by this zero-order reconstruction will be mitigated.
        // PJ 2016-04-12
        FVCell src_cell, ghost0;
        BoundaryCondition bc = blk.bc[which_boundary];
        if (bc.outsigns[f.i_bndry] == 1) {
	    src_cell = f.left_cell;
	    ghost0 = f.right_cell;
	} else {
	    src_cell = f.right_cell;
	    ghost0 = f.left_cell;
	}
	ghost0.fs.copy_values_from(src_cell.fs);
	reflect_normal_velocity(ghost0.fs, f);
	if (blk.myConfig.MHD) { reflect_normal_magnetic_field(ghost0.fs, f); }
    } // end apply_for_interface_unstructured_grid()

    @nogc
    override void apply_unstructured_grid(double t, int gtl, int ftl)
    {
        // In contrast with the structured-grid implementation, below,
        // we use a single source cell because we're not sure that
        // the next cell in the interior list (if there is one) will
        // be positioned as a mirror image of the second ghost cell.
        // If the grid is clustered toward the boundary, the error
        // introduced by this zero-order reconstruction will be mitigated.
        // PJ 2016-04-12
        FVCell src_cell, ghost0;
        BoundaryCondition bc = blk.bc[which_boundary];
        foreach (i, f; bc.faces) {
            if (bc.outsigns[i] == 1) {
                src_cell = f.left_cell;
                ghost0 = f.right_cell;
            } else {
                src_cell = f.right_cell;
                ghost0 = f.left_cell;
            }
            ghost0.fs.copy_values_from(src_cell.fs);
            reflect_normal_velocity(ghost0.fs, f);
            if (blk.myConfig.MHD) { reflect_normal_magnetic_field(ghost0.fs, f); }
        } // end foreach face
    } // end apply_unstructured_grid()

    @nogc
    override void apply_for_interface_structured_grid(double t, int gtl, int ftl, FVInterface f)
    {
        FVCell src_cell, dest_cell;
        auto copy_opt = CopyDataOption.minimal_flow;
        auto blk = cast(SFluidBlock) this.blk;
        assert(blk !is null, "Oops, this should be an SFluidBlock object.");
        BoundaryCondition bc = blk.bc[which_boundary];
        foreach (n; 0 .. blk.n_ghost_cell_layers) {
            if (bc.outsigns[f.i_bndry] == 1) {
                src_cell = f.left_cells[n];
                dest_cell = f.right_cells[n];
            } else {
                src_cell = f.right_cells[n];
                dest_cell = f.left_cells[n];
            }
            dest_cell.copy_values_from(src_cell, copy_opt);
            reflect_normal_velocity(dest_cell.fs, f);
            if (blk.myConfig.MHD) {
                reflect_normal_magnetic_field(dest_cell.fs, f);
            }
        }
    } // end apply_for_interface_structured_grid()

    @nogc
    override void apply_structured_grid(double t, int gtl, int ftl)
    {
        FVCell src_cell, dest_cell;
        auto copy_opt = CopyDataOption.minimal_flow;
        auto blk = cast(SFluidBlock) this.blk;
        assert(blk !is null, "Oops, this should be an SFluidBlock object.");
        BoundaryCondition bc = blk.bc[which_boundary];
        foreach (i, f; bc.faces) {
            foreach (n; 0 .. blk.n_ghost_cell_layers) {
                if (bc.outsigns[i] == 1) {
                    src_cell = f.left_cells[n];
                    dest_cell = f.right_cells[n];
                } else {
                    src_cell = f.right_cells[n];
                    dest_cell = f.left_cells[n];
                }

                //auto Bxtemp = dest_cell.fs.B.x; 
                //auto Bytemp = dest_cell.fs.B.y;

                dest_cell.copy_values_from(src_cell, copy_opt);

                //dest_cell.fs.B.x = Bxtemp;
                //dest_cell.fs.B.y = Bytemp;

                reflect_normal_velocity(dest_cell.fs, f);
                if (blk.myConfig.MHD) {
                    reflect_normal_magnetic_field(dest_cell.fs, f);
                    
                    if(dest_cell.pos[0].x > -0.4136 && dest_cell.pos[0].x < 0.4136){
                        dest_cell.fs.B.x = -(((0.1)*(0.82/2)^^3)/(2*(((dest_cell.pos[0].x +0.)^^2+(dest_cell.pos[0].y +0.0)^^2)^^0.5)^^5)) * (2*(dest_cell.pos[0].x +0.)^^2 - (dest_cell.pos[0].y +0.0)^^2);
                        dest_cell.fs.B.y = -(((0.1)*(0.82/2)^^3)/(2*(((dest_cell.pos[0].x +0.)^^2+(dest_cell.pos[0].y +0.0)^^2)^^0.5)^^5)) * (3*(dest_cell.pos[0].x +0.)*(dest_cell.pos[0].y +0.0));
                    }

                    // Temporary BCs for Hartmann Flow Problem:
                    //if(dest_cell.pos[0].y > 0.5){ f.fs.vel.x = 1.0; dest_cell.fs.vel.x = 1.0; f.fs.B.x = 0.0; dest_cell.fs.B.x = 0.0;}
                    //if(dest_cell.pos[0].y < 0.5){ f.fs.vel.x = -1.0; dest_cell.fs.vel.x = -1.0; f.fs.B.x = 0.0; dest_cell.fs.B.x = 0.0;}
                }
            }
        }
    } // end apply_structured_grid()
} // end class GhostCellInternalCopyThenReflect
