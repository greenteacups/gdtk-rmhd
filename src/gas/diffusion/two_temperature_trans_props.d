/**
 * two_temperature_trans_props.d
 *
 * Author: Rowan G.
 * Date: 2021-03-16
 * History: 2021-03-16 -- code ported from two_temperature air model.
 *
 * References
 * ----------
 * Gnoffo, Gupta and Shin (1989)
 * Conservation equations and physical models for hypersonic air flows
 * in thermal and chemical nonequilibrium.
 * NASA TP-2867, February 1989, NASA Langley Research Center
 *
 * Gupta, Yos and Thompson (1989)
 * A review of reaction rate and thermodynamic and transport properties
 * for the 11-species air model for chemical and thermal nonequilibrium
 * calculations to 30,000 K.
 * NASA TM-101528, February 1989, NASA Langley Research Center
 **/

module gas.diffusion.two_temperature_trans_props;

import std.math;
import std.string;
import std.conv;

import util.lua;
import util.lua_service;
import nm.number;

import gas;
import gas.diffusion.transport_properties_model;

class TwoTemperatureTransProps : TransportPropertiesModel {
public:

    this(lua_State *L, string[] speciesNames)
    {
        mNSpecies = to!int(speciesNames.length);
        double[] molMasses;
        mMolMasses.length = mNSpecies;
        mParticleMass.length = mNSpecies;
        mMolef.length = mNSpecies;
        allocateArraysForCollisionIntegrals();
        foreach (isp, spName; speciesNames) {
            if (spName == "e-") mElectronIdx = to!int(isp);
            lua_getglobal(L, "db");
            lua_getfield(L, -1, spName.toStringz);
            double m = getDouble(L, -1, "M");
            mMolMasses[isp] = m;
            mParticleMass[isp] = 1000.0*m/Avogadro_number; // kg -> g
            string type = getString(L, -1, "type");
            if (type == "molecule") {
                mMolecularSpecies ~= to!int(isp);
            }
            lua_pop(L, 1);
            lua_pop(L, 1);
        }
        // Fill in support data for collision integrals
        lua_getglobal(L, "db");
        lua_getfield(L, -1, "cis");
        foreach (isp; 0 .. mNSpecies) {
            foreach (jsp; 0 .. isp+1) {
                string key = speciesNames[isp] ~ ":" ~ speciesNames[jsp];
                lua_getfield(L, -1, key.toStringz);
                if (lua_isnil(L, -1)) {
                    lua_pop(L, 1);
                    // Try reverse order, eg. N2:O2 --> O2:N2
                    key = speciesNames[jsp] ~ ":" ~ speciesNames[isp];
                    lua_getfield(L, -1, key.toStringz);
                    if (lua_isnil(L, -1)) {
                        // There's still a problem, can't find entry for CI data.
                        string msg = format("Collision integral data for '%s' is missing.\n", key);
                        throw new Error(msg);
                    }
                }
                lua_getfield(L, -1, "pi_Omega_11");
                mA_11[isp][jsp] = getDouble(L, -1, "A");
                mB_11[isp][jsp] = getDouble(L, -1, "B");
                mC_11[isp][jsp] = getDouble(L, -1, "C");
                mD_11[isp][jsp] = getDouble(L, -1, "D");
                lua_pop(L, 1); // pop: pi_Omega_11
                lua_getfield(L, -1, "pi_Omega_22");
                mA_22[isp][jsp] = getDouble(L, -1, "A");
                mB_22[isp][jsp] = getDouble(L, -1, "B");
                mC_22[isp][jsp] = getDouble(L, -1, "C");
                mD_22[isp][jsp] = getDouble(L, -1, "D");
                lua_pop(L, 1); // pop: pi_Omega_22
                lua_pop(L, 1); // pop: collision pair.
            }
        }
        lua_pop(L, 1); // pop: cis
        lua_pop(L, 1); // pop: db

        // Compute alphas
        foreach (isp; 0 .. mNSpecies) {
            foreach (jsp; 0 .. mNSpecies) {
                double M_isp = mMolMasses[isp];
                double M_jsp = mMolMasses[jsp];
                mMu[isp][jsp] = (M_isp*M_jsp)/(M_isp + M_jsp);
                mMu[isp][jsp] *= 1000.0; // convert kg/mole --> g/mole
                double M_ratio = M_isp/M_jsp;
                double numer = (1.0 - M_ratio)*(0.45 - 2.54*M_ratio);
                double denom = (1.0 + M_ratio)^^2;
                mAlpha[isp][jsp] = 1.0 + numer/denom;
            }
        }
    }

    void allocateArraysForCollisionIntegrals()
    {
        mMu.length = mNSpecies;
        mAlpha.length = mNSpecies;
        mA_11.length = mNSpecies;
        mB_11.length = mNSpecies;
        mC_11.length = mNSpecies;
        mD_11.length = mNSpecies;
        mDelta_11.length = mNSpecies;
        mA_22.length = mNSpecies;
        mB_22.length = mNSpecies;
        mC_22.length = mNSpecies;
        mD_22.length = mNSpecies;
        mDelta_22.length = mNSpecies;
        foreach (isp; 0 .. mNSpecies) {
            mMu[isp].length = mNSpecies;
            mAlpha[isp].length = mNSpecies;
            mA_11[isp].length = isp+1;
            mB_11[isp].length = isp+1;
            mC_11[isp].length = isp+1;
            mD_11[isp].length = isp+1;
            mDelta_11[isp].length = mNSpecies;
            mA_22[isp].length = isp+1;
            mB_22[isp].length = isp+1;
            mC_22[isp].length = isp+1;
            mD_22[isp].length = isp+1;
            mDelta_22[isp].length = mNSpecies;
        }
    }
    
    @nogc
    override void updateTransProps(GasState gs)
    {
        massf2molef(gs.massf, mMolMasses, mMolef);
        // Computation of transport coefficients via collision integrals.
        // Equations follow those in Gupta et al. (1990)
        computeDelta22(gs);
        computeDelta11(gs);

        // Compute mixture viscosity.
        number sumA = 0.0;
        number denom;
        foreach (isp; 0 .. mNSpecies) {
            denom = 0.0;
            foreach (jsp; 0 .. mNSpecies) {
                denom += mMolef[jsp]*mDelta_22[isp][jsp];
            }
            if (isp == mElectronIdx) continue;
            sumA += mParticleMass[isp]*mMolef[isp]/denom;
        }
        // Add term if electron present.
        if (mElectronIdx != -1) {
            // An additional term is required in the mixture viscosity.
            denom = 0.0;
            foreach (jsp; 0 .. mNSpecies) {
                denom += mMolef[jsp]*mDelta_22[mElectronIdx][jsp];
            }
            sumA += mParticleMass[mElectronIdx]*mMolef[mElectronIdx]/denom;

        }
        gs.mu = sumA * (1.0e-3/1.0e-2); // convert g/(cm.s) -> kg/(m.s)
        
        // Compute component thermal conductivities
        // k in transrotational = k_tr + k_rot
        // k in vibroelectronic = k_ve + k_E
        // 1. k_tr
        sumA = 0.0;
        foreach (isp; 0 .. mNSpecies) {
            denom = 0.0;
            foreach (jsp; 0 .. mNSpecies) {
                if (jsp != mElectronIdx) {
                    denom += mAlpha[isp][jsp]*mMolef[jsp]*mDelta_22[isp][jsp];
                }
                else {
                    denom += 3.54*mAlpha[isp][jsp]*mMolef[jsp]*mDelta_22[isp][jsp];
                }
            }
            if (isp == mElectronIdx) continue;
            sumA += mMolef[isp]/denom;
        }
        double kB_erg = 1.38066e-16; // erg/K
        number k_tr = 2.3901e-8*(15./4.)*kB_erg*sumA;
        k_tr *= (4.184/1.0e-2); // cal/(cm.s.K) --> J/(m.s.K)

        // 2. k_rot
        // Assuming fully excited, eq (75) in Gnoffo
        number k_rot = 0.0;
        foreach (isp; mMolecularSpecies) {
            denom = 0.0;
            foreach (jsp; 0 .. mNSpecies) {
                denom += mMolef[jsp]*mDelta_11[isp][jsp];
            }
            k_rot += mMolef[isp]/denom;
        }
        k_rot *= 2.3901e-8*kB_erg;
        k_rot *= (4.184/1.0e-2); // cal/(cm.s.K) --> J/(m.s.K)
        // Eq (76) in Gnoffo.
        gs.k = k_tr + k_rot;

        // 3. k_vib
        // Eq (77) in Gnoffo
        number k_vib = k_rot;

        // 4. k_e
        number k_E = 0.0;
        if (mElectronIdx != -1) {
            // electron present.
            denom = 0.0;
            foreach (jsp; 0 .. mNSpecies) {
                denom += 1.45*mMolef[jsp]*mDelta_22[mElectronIdx][jsp];
            }
            k_E = mMolef[mElectronIdx]/denom;
            k_E *= 2.3901e-8*(15./4.)*kB_erg;
            k_E *= (4.184/1.0e-2); // cal/(cm.s.K) --> J/(m.s.K)
        }
        gs.k_modes[0] = k_vib + k_E;
    }

    /*
    void binaryDiffusionCoefficients(in GasState gs, ref number[][] D)
    {
        // TODO.
        throw new Error("not implemented.");
    }
    */

private:
    
    double mR_U_cal = 1.987; // cal/(mole.K)
    int mNSpecies;
    int mElectronIdx = -1;
    int[] mMolecularSpecies;
    double[] mMolMasses;
    double[] mParticleMass;
    // working array space
    number[] mMolef;
    number[][] mA_11, mB_11, mC_11, mD_11, mDelta_11, mAlpha;
    number[][] mA_22, mB_22, mC_22, mD_22, mDelta_22, mMu;

    @nogc
    void computeDelta11(GasState gs)
    {
        // TODO: Correct collision cross-sections when p_e != 1 atm.
        double kB = Boltzmann_constant;
        number T_CI;
        number log_T_CI;

        foreach (isp; 0 .. mNSpecies) {
            foreach (jsp; 0 .. isp+1) {
                 if (isp != mElectronIdx) {
                    // heavy-particle colliders: use transrotational temperature in calculation
                    T_CI = gs.T;
                    log_T_CI = log(T_CI);
                }
                else {
                    // collisions with electron: use vibroelectronic temperature in calculation
                    T_CI = gs.T_modes[0];
                    log_T_CI = log(T_CI);
                }
                number expnt = mA_11[isp][jsp]*(log_T_CI)^^2 + mB_11[isp][jsp]*log_T_CI + mC_11[isp][jsp];
                number pi_Omega_11 = exp(mD_11[isp][jsp])*pow(T_CI, expnt); 
                mDelta_11[isp][jsp] = (8.0/3)*1.546e-20*sqrt(2.0*mMu[isp][jsp]/(to!double(PI)*mR_U_cal*T_CI))*pi_Omega_11;
                mDelta_11[jsp][isp] = mDelta_11[isp][jsp];
            }
        }
    }

    @nogc
    void computeDelta22(GasState gs)
    {
        // TODO: Correct collision cross-sections when p_e != 1 atm.
        double kB = Boltzmann_constant;
        number T_CI;
        number log_T_CI;

        foreach (isp; 0 .. mNSpecies) {
            foreach (jsp; 0 .. isp+1) {
                if (isp != mElectronIdx) {
                    // heavy-particle colliders: use transrotational temperature in calculation
                    T_CI = gs.T;
                    log_T_CI = log(T_CI);
                }
                else {
                    // collisions with electron: use vibroelectronic temperature in calculation
                    T_CI = gs.T_modes[0];
                    log_T_CI = log(T_CI);
                }
                number expnt = mA_22[isp][jsp]*(log_T_CI)^^2 + mB_22[isp][jsp]*log_T_CI + mC_22[isp][jsp];
                number pi_Omega_22 = exp(mD_22[isp][jsp])*pow(T_CI, expnt); 
                mDelta_22[isp][jsp] = (16./5)*1.546e-20*sqrt(2.0*mMu[isp][jsp]/(to!double(PI)*mR_U_cal*T_CI))*pi_Omega_22;
                mDelta_22[jsp][isp] = mDelta_22[isp][jsp];
            }
        }
    }
    
}


version(two_temperature_trans_props_test)
{
    int main()
    {
        import util.msg_service;

        FloatingPointControl fpctrl;
        // Enable hardware exceptions for division by zero, overflow to infinity,
        // invalid operations, and uninitialized floating-point variables.
        // Copied from https://dlang.org/library/std/math/floating_point_control.html
        fpctrl.enableExceptions(FloatingPointControl.severeExceptions);

        auto L = init_lua_State();
        doLuaFile(L, "sample-data/N2-N.lua");
        string[] speciesNames;
        getArrayOfStrings(L, LUA_GLOBALSINDEX, "species", speciesNames);
        auto ttp = new TwoTemperatureTransProps(L, speciesNames);
        lua_close(L);
        auto gs = new GasState(2, 1);
        gs.p = 1.0e5;
        gs.T = 2000.0;
        gs.T_modes[0] = 3000.0;
        gs.massf[0] = 0.2;
        gs.massf[1] = 0.8;

        ttp.updateTransProps(gs);

        import std.stdio;
        writefln("mu= %.6e  k= %.6e  k_v= %.6e\n", gs.mu, gs.k, gs.k_modes[0]);

        return 0;
    }
    
}