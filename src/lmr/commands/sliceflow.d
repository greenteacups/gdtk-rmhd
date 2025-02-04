/**
 * Module for slicing flow-field snapshots, picking out specific data.
 *
 * Authors: RJG, PJ, KAD, NNG
 * Date: 2024-03-01, adapted from probeflow.d and src/eilmer/postprocess.d
 */

module lmr.commands.sliceflow;

import std.algorithm;
import std.array;
import std.conv : to;
import std.file;
import std.format : format;
import std.getopt;
import std.range;
import std.regex : regex, replaceAll;
import std.stdio;
import std.string;

import lmr.commands.cmdhelper;
import lmr.commands.command;
import lmr.fileutil;
import lmr.flowsolution;
import lmr.globalconfig;
import lmr.init : initConfiguration;
import lmr.lmrconfig : lmrCfg;

Command sliceFlowCmd;

string cmdName = "slice-flow";

static this()
{
    sliceFlowCmd.main = &main_;
    sliceFlowCmd.description = "Slice flow-field snapshots (for structured grids).";
    sliceFlowCmd.shortDescription = sliceFlowCmd.description;
    sliceFlowCmd.helpMsg = format(
`lmr %s [options]

Slice flow-field snapshots across index-directions,
for a selection of flow field variables.
The really only makes sense for structured-grid blocks.

If no selection of variable names is supplied, then the default action is
to report all flow field variables (--names=all).

If no options related to snapshot selection are given,
then the default is to process the final snapshot.

options ([+] can be repeated):

 -n, --names
     comma separated list of variable names for reporting
     examples:
       --names=rho,vel.x,vel.y
       --names=rho
     default:
       --names=all
     The output will always start with pos.x,pos.y and, for 3D, pos.z.

 --add-vars
     comma separated array of auxiliary variables to add to the flow solution
     eg. --add-vars=mach,pitot
     Other variables include:
         total-h, total-p, total-T,
         enthalpy, entropy, molef, conc,
         Tvib (for some gas models)
         nrf (non-rotating-frame velocities)
         cyl (cylindrical coordinates: r, theta)

 -l, --slice-list
     slices the flow field in a range of blocks by accepting a string of the form
     "blk-range,i-range,j-range:k-range;"

     examples:
       --slice-list=0:2,:,$,0
       will select blocks 0 and 1, writing out the top strip (j=njc-1) of cells, stepping in i
       Note that you can specify the last value of any index with $.

       --slice-list="0:2,:,0,0;2,$,:,0"
       will select blocks 0 and 1, writing out a strip of cells stepping in i, keeping j=0, k=0, plus
       from block 2, write out a strip of cells stepping in j, keeping i=nic-1 and k=0
       Note that you need the quotes to stop the shell from cutting your command at the semicolon.

     default: none (report nothing)

 -s, --snapshot[s]+
     comma separated array of snapshots to convert
     Note that only the last one will be processed.
     examples:
       --snapshots=0,1,5 : processes snapshots 0, 1 and 5
       --snapshot=2 : processes snapshot 2 only
       --snapshot 1  --snapshot 4 : processes snapshots 1 and 4
     default: none (empty array)


 -f, --final
     process the final snapshot
     default: false

 -a, --all
     process all snapshots
     default: false

 -o, --output
     write output to a file
     example:
       --output=norms-data.txt
     default: none (just write to STDOUT)

 -v, --verbose [+]
     Increase verbosity.

`, cmdName);

}

int main_(string[] args)
{
    int verbosity = 0;
    int[] snapshots;
    bool finalSnapshot = false;
    bool allSnapshots = false;
    bool binaryFormat = false;
    string namesStr;
    string outFilename;
    string sliceListStr;
    string luaRefSoln;
    string addVarsStr;
    try {
        getopt(args,
               config.bundling,
               "v|verbose+", &verbosity,
               "n|names", &namesStr,
               "s|snapshots|snapshot", &snapshots,
               "f|final", &finalSnapshot,
               "a|all", &allSnapshots,
               "o|output", &outFilename,
               "l|slice-list", &sliceListStr,
               "add-vars", &addVarsStr
               );
    } catch (Exception e) {
        writefln("Eilmer %s program quitting.", cmdName);
        writeln("There is something wrong with the command-line arguments/options.");
        writeln(e.msg);
        return 1;
    }

    if (verbosity > 0) {
        writefln("lmr %s: Begin program.", cmdName);
    }

    string[] addVarsList;
    addVarsStr = addVarsStr.strip();
    addVarsStr = addVarsStr.replaceAll(regex("\""), "");
    if (addVarsStr.length > 0) {
        addVarsList = addVarsStr.split(",");
    }
    if (namesStr.empty) {
        // add default, for when nothing supplied
        namesStr ~= "all";
    }
    // Use stdout if no output filename is supplied,
    // or open a file ready for use if one is.
    File outfile = outFilename.empty() ? stdout : File(outFilename, "w");
    //
    initConfiguration(); // To read in GlobalConfig
    auto availSnapshots = determineAvailableSnapshots();
    auto snaps2process = determineSnapshotsToProcess(availSnapshots, snapshots, allSnapshots, finalSnapshot);
    auto snap = snaps2process[$-1];
    if (verbosity > 0) {
        writefln("lmr %s: Slicing flow field for snapshot %s.", cmdName, snap);
    }
    sliceListStr = sliceListStr.strip();
    sliceListStr = sliceListStr.replaceAll(regex("\""), "");
    //
    auto soln = new FlowSolution(to!int(snap), GlobalConfig.nFluidBlocks);
    bool threeD =  canFind(soln.flowBlocks[0].variableNames, "pos.z");
    soln.add_aux_variables(addVarsList);
    //
    string[] namesList;
    auto namesVariables = namesStr.split(",");
    foreach (var; namesVariables) {
        var = strip(var);
        if (var.toLower() == "all") {
            foreach (name; soln.flowBlocks[0].variableNames) {
                if (!canFind(["pos.x","pos.y","pos.z"], name)) { namesList ~= name; }
            }
        } else {
            if (canFind(soln.flowBlocks[0].variableNames, var)) {
                namesList ~= var;
            } else {
                writefln("Ignoring requested variable: %s", var);
                writeln("This does not appear in list of flow solution variables.");
            }
        }
    }
    string headerStr = "pos.x pos.y";
    if (threeD) headerStr ~= " pos.z";
    foreach (var; namesList) { headerStr ~= " " ~ var; }
    outfile.writeln(headerStr);
    //
    foreach (sliceStr; sliceListStr.split(";")) {
        auto rangeStrings = sliceStr.split(",");
        auto blk_range = decode_range_indices(rangeStrings[0], 0, soln.nBlocks);
        foreach (ib; blk_range[0] .. blk_range[1]) {
            auto blk = soln.flowBlocks[ib];
            // We need to do the decode in the context of each block because
            // the upper limits to the indices are specific to the block.
            auto i_range = decode_range_indices(rangeStrings[1], 0, blk.nic);
            auto j_range = decode_range_indices(rangeStrings[2], 0, blk.njc);
            auto k_range = decode_range_indices(rangeStrings[3], 0, blk.nkc);
            foreach (k; k_range[0] .. k_range[1]) {
                foreach (j; j_range[0] .. j_range[1]) {
                    foreach (i; i_range[0] .. i_range[1]) {
                        outfile.write(format(" %g %g", soln.flowBlocks[ib]["pos.x", i, j, k],
                                             soln.flowBlocks[ib]["pos.y", i, j, k]));
                        if (threeD) {
                            outfile.write(format(" %g", soln.flowBlocks[ib]["pos.z", i, j, k]));
                        }
                        foreach (var; namesList) {
                            outfile.write(format(" %g", soln.flowBlocks[ib][var, i, j, k]));
                        }
                        outfile.write("\n");
                    }
                }
            }
        } // end foreach ib
    } // end foreach sliceStr

    if (verbosity > 0) {
        writefln("lmr %s: Done.", cmdName);
    }
    outfile.close();
    return 0;
}
