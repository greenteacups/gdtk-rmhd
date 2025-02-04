// flow_state_copy_from_transient_profile.d

module lmr.bc.ghost_cell_effect.flow_state_copy_from_transient_profile;

import std.conv;
import std.file;
import std.json;
import std.math;
import std.stdio;
import std.string;

import gas;
import geom;

import lmr.bc;
import lmr.flowstate;
import lmr.fluidblock;
import lmr.fvinterface;
import lmr.globalconfig;
import lmr.globaldata;
import lmr.sfluidblock;


class GhostCellFlowStateCopyFromTransientProfile : GhostCellEffect {
public:
    this(int id, int boundary, string fileName, string match)
    {
        super(id, boundary, "flowStateCopyFromTransientProfile");
        fprofile = new TransientFlowProfile(fileName, match);
    }

    override string toString() const
    {
        return format("flowStateCopyFromTransientProfile(filename=\"%s\", match=\"%s\")",
                      fprofile.fileName, fprofile.posMatch);
    }

    override void apply_for_interface_unstructured_grid(double t, int gtl, int ftl, FVInterface f)
    {
        BoundaryCondition bc = blk.bc[which_boundary];
        auto ghost0 = (bc.outsigns[f.i_bndry] == 1) ? f.right_cell : f.left_cell;
        fprofile.set_time_interpolation(t);
        fprofile.set_flowstate(ghost0.fs, ghost0.id, ghost0.pos[0]);
        fprofile.adjust_velocity(ghost0.fs, ghost0.pos[0], blk.omegaz);
    }

    // not @nogc
    override void apply_unstructured_grid(double t, int gtl, int ftl)
    {
        BoundaryCondition bc = blk.bc[which_boundary];
        fprofile.set_time_interpolation(t);
        foreach (i, f; bc.faces) {
            auto ghost0 = (bc.outsigns[i] == 1) ? f.right_cell : f.left_cell;
            fprofile.set_flowstate(ghost0.fs, ghost0.id, ghost0.pos[0]);
            fprofile.adjust_velocity(ghost0.fs, ghost0.pos[0], blk.omegaz);
        }
    } // end apply_unstructured_grid()

    // not @nogc
    override void apply_for_interface_structured_grid(double t, int gtl, int ftl, FVInterface f)
    {
        auto blk = cast(SFluidBlock) this.blk;
        assert(blk !is null, "Oops, this should be an SFluidBlock object.");
        BoundaryCondition bc = blk.bc[which_boundary];
        fprofile.set_time_interpolation(t);
        foreach (n; 0 .. blk.n_ghost_cell_layers) {
            auto ghost = (bc.outsigns[f.i_bndry] == 1) ? f.right_cells[n] : f.left_cells[n];
            fprofile.set_flowstate(ghost.fs, ghost.id, ghost.pos[0]);
            fprofile.adjust_velocity(ghost.fs, ghost.pos[0], blk.omegaz);
        }
    } // end apply_for_interface_structured_grid()

    // not @nogc
    override void apply_structured_grid(double t, int gtl, int ftl)
    {
        auto blk = cast(SFluidBlock) this.blk;
        assert(blk !is null, "Oops, this should be an SFluidBlock object.");
        BoundaryCondition bc = blk.bc[which_boundary];
        fprofile.set_time_interpolation(t);
        foreach (i, f; bc.faces) {
            foreach (n; 0 .. blk.n_ghost_cell_layers) {
                auto ghost = (bc.outsigns[i] == 1) ? f.right_cells[n] : f.left_cells[n];
                fprofile.set_flowstate(ghost.fs, ghost.id, ghost.pos[0]);
                fprofile.adjust_velocity(ghost.fs, ghost.pos[0], blk.omegaz);
            }
        }
    } // end apply_structured_grid()

private:
    TransientFlowProfile fprofile;

} // end class GhostCellFlowStateCopyFromTransientProfile
