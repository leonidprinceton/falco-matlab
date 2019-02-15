% Copyright 2018, by the California Institute of Technology. ALL RIGHTS
% RESERVED. United States Government Sponsorship acknowledged. Any
% commercial use must be negotiated with the Office of Technology Transfer
% at the California Institute of Technology.
% -------------------------------------------------------------------------
%
% function Eout = model_compact_general(mp, lambda, Ein, normFac, flagEval)
% 
% This function produces the electric field based on the knowledge
% available to the user in what is called the "compact model." Usually, 
% aberrations are condensed to the input pupil (and possibly also the 
% output pupil) after phase retrieval, COFFEE, or similar since aberrations
% cannot accurately enough be attributed to individual optics. That makes 
% this model primarily a Fourier model, with Fresnel propagation only 
% useful and needed between the deformable mirrors and key coronagraph 
% optics known to be out of the pupil or focal planes.
%
% REVISION HISTORY:
% --------------
% Modified on 2019-02-14 by G. Ruane to handle scalar vortex FPMs
% Modified on 2019-02-11 by A.J. Riggs to have all coronagraph types
% together.
% Modified on 2018-01-23 by A.J. Riggs to allow DM1 to not be at a pupil
%  and to have an aperture stop.
% Modified on 2017-11-09 by A.J. Riggs to remove the Jacobian calculation.
% Modified on 2017-10-17 by A.J. Riggs to have model_compact.m be a wrapper. All the 
%  actual compact models have been moved to sub-routines for clarity.
% Modified on 19 June 2017 by A.J. Riggs to use lower resolution than the
%   full model.
% model_compact.m - 18 August 2016: Modified from hcil_model.m
% hcil_model.m - 18 Feb 2015: Modified from HCIL_model_lab_BB_v3.m
% ---------------
%
% INPUTS:
% - mp = structure of model parameters
% - lambda
% - Ein
% - normFac
% - flagEval
%
%
% OUTPUTS:
% - Eout = electric field in the final focal plane
%
%
% NOTE: In wrapper above this that chooses layout, need to define mp.FPM.mask
% like this:
% mp.FPM.mask = falco_gen_HLC_FPM_complex_trans_mat( mp,modvar.sbpIndex,modvar.wpsbpIndex,'compact');


function Eout = model_compact_general(mp, lambda, Ein, normFac, flagEval)

mirrorFac = 2; % Phase change is twice the DM surface height.
NdmPad = mp.compact.NdmPad;

if(flagEval) %--Higher resolution at final focal plane for computing stats
    dxi = mp.F4.eval.dxi;
    Nxi = mp.F4.eval.Nxi;
    deta = mp.F4.eval.deta;
    Neta = mp.F4.eval.Neta; 
else
    dxi = mp.F4.dxi;
    Nxi = mp.F4.Nxi;
    deta = mp.F4.deta;
    Neta = mp.F4.Neta; 
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Masks and DM surfaces
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%--Compute the DM surfaces for the current DM commands
if(any(mp.dm_ind==1)); DM1surf = falco_gen_dm_surf(mp.dm1, mp.dm1.compact.dx, NdmPad); else; DM1surf = 0; end %--Pre-compute the starting DM1 surface
if(any(mp.dm_ind==2)); DM2surf = falco_gen_dm_surf(mp.dm2, mp.dm2.compact.dx, NdmPad); else; DM2surf = 0; end %--Pre-compute the starting DM2 surface

pupil = padOrCropEven(mp.P1.compact.mask,NdmPad);
Ein = padOrCropEven(Ein,mp.compact.NdmPad);

if(mp.flagDM1stop); DM1stop = padOrCropEven(mp.dm1.compact.mask, NdmPad); else; DM1stop = ones(NdmPad); end
if(mp.flagDM2stop); DM2stop = padOrCropEven(mp.dm2.compact.mask, NdmPad); else; DM2stop = ones(NdmPad); end

if(mp.useGPU)
    pupil = gpuArray(pupil);
    Ein = gpuArray(Ein);
    if(any(mp.dm_ind==1)); DM1surf = gpuArray(DM1surf); end
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Propagation
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%--Define pupil P1 and Propagate to pupil P2
EP1 = pupil.*Ein; %--E-field at pupil plane P1
EP2 = propcustom_2FT(EP1,mp.centering); %--Forward propagate to the next pupil plane (P2) by rotating 180 deg.

%--Propagate from P2 to DM1, and apply DM1 surface and aperture stop
if( abs(mp.d_P2_dm1)~=0 ); Edm1 = propcustom_PTP(EP2,mp.P2.compact.dx*NdmPad,lambda,mp.d_P2_dm1); else Edm1 = EP2; end  %--E-field arriving at DM1
Edm1 = DM1stop.*exp(mirrorFac*2*pi*1i*DM1surf/lambda).*Edm1; %--E-field leaving DM1

%--Propagate from DM1 to DM2, and apply DM2 surface and aperture stop
Edm2 = propcustom_PTP(Edm1,mp.P2.compact.dx*NdmPad,lambda,mp.d_dm1_dm2); 
Edm2 = DM2stop.*exp(mirrorFac*2*pi*1i*DM2surf/lambda).*Edm2;

%--Back-propagate to pupil P2
if( mp.d_P2_dm1 + mp.d_dm1_dm2 == 0 ); EP2eff = Edm2; else; EP2eff = propcustom_PTP(Edm2,mp.P2.compact.dx*NdmPad,lambda,-1*(mp.d_dm1_dm2 + mp.d_P2_dm1)); end %--Back propagate to pupil P2

%--Rotate 180 degrees to propagate to pupil P3
EP3 = propcustom_2FT(EP2eff, mp.centering);

%--Apply apodizer mask.
if(mp.flagApod)
    EP3 = mp.P3.compact.mask.*padOrCropEven(EP3, mp.P3.compact.Narr); 
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%  Select propagation based on coronagraph type   %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%--Don't apply FPM if normalization value is being found
if(normFac==0)
    switch lower(mp.coro)
        case{'vortex','vc','avc'}
            EP4 = propcustom_2FT(EP3, mp.centering);
        case{'splc','flc'}
            %--MFT from SP to FPM (i.e., P3 to F3)
            EF3inc = propcustom_mft_PtoF(EP3, mp.fl,lambda,mp.P2.compact.dx,mp.F3.compact.dxi,mp.F3.compact.Nxi,mp.F3.compact.deta,mp.F3.compact.Neta,mp.centering); %--E-field incident upon the FPM
            %--MFT from FPM to Lyot Plane (i.e., F3 to P4)
            EP4 = propcustom_mft_FtoP(EF3inc,mp.fl,lambda,mp.F3.compact.dxi,mp.F3.compact.deta,mp.P4.compact.dx,mp.P4.compact.Narr,mp.centering); %--E-field incident upon the Lyot stop 
        case{'lc,aplc'}
            %--Re-image to Lyot plane
            EP4noFPM = propcustom_2FT(EP3,mp.centering); %--Propagate forward another pupil plane 
            EP4 = padOrCropEven(EP4noFPM,mp.P4.compact.Narr); %--Crop down to the size of the Lyot stop opening           
        case{'hlc'}
            %--Complex transmission of the points outside the FPM (just fused silica with optional dielectric and no metal).
            t_Ti_base = 0;
            t_Ni_vec = 0;
            t_PMGI_vec = 1e-9*mp.t_diel_bias_nm; % [meters]
            pol = 2;
            [tCoef, ~] = falco_thin_film_material_def(lambda, mp.aoi, t_Ti_base, t_Ni_vec, t_PMGI_vec, lambda*mp.FPM.d0fac, pol);
            transOuterFPM = tCoef;
            %--Re-image to Lyot plane and multiply by the substrate's complex transmission
            EP4noFPM = propcustom_2FT(EP3,mp.centering); %--Propagate forward another pupil plane 
            EP4noFPM = padOrCropEven(EP4noFPM,mp.P4.compact.Narr); %--Crop down to the size of the Lyot stop opening
            EP4 = transOuterFPM*EP4noFPM; %--Apply the phase and amplitude change from the FPM's outer complex transmission.
        case{'ehlc'}
            %--Complex transmission of the points outside the inner part of the FPM (just fused silica with optional dielectric and no metal).
            t_Ti_base = 0;
            t_Ni_vec = 0;
            t_PMGI_vec = 1e-9*mp.t_diel_bias_nm; % [meters]
            pol = 2;
            [tCoef, ~] = falco_thin_film_material_def(lambda, mp.aoi, t_Ti_base, t_Ni_vec, t_PMGI_vec, lambda*mp.FPM.d0fac, pol);
            transOuterFPM = tCoef;
            
            %--MFT from apodizer plane to FPM (i.e., P3 to F3)
            EF3inc = propcustom_mft_PtoF(EP3, mp.fl,lambda,mp.P2.compact.dx,mp.F3.compact.dxi,mp.F3.compact.Nxi,mp.F3.compact.deta,mp.F3.compact.Neta,mp.centering); %--E-field incident upon the FPM
            %--Do NOT apply FPM if normalization value is being found
            EF3 = transOuterFPM*EF3inc;
            %--MFT from FPM to Lyot Plane (i.e., F3 to P4)
            EP4 = propcustom_mft_FtoP(EF3,mp.fl,lambda,mp.F3.compact.dxi,mp.F3.compact.deta,mp.P4.compact.dx,mp.P4.compact.Narr,mp.centering);
            
        case{'fohlc'}
            %--Do NOT apply FPM if normalization value is being found
            EP4noFPM = propcustom_2FT(EP3,mp.centering); %--Propagate forward another pupil plane 
            EP4 = padOrCropEven(EP4noFPM,mp.P4.compact.Narr); %--Crop down to the size of the Lyot stop opening
    end
    
else
    switch lower(mp.coro)
        case{'vortex','vc','avc'}
            % Get FPM charge 
            if(numel(mp.F3.VortexCharge)==1)
                % single value indicates fully achromatic mask
                charge = mp.F3.VortexCharge;
            else
                % Passing an array for mp.F3.VortexCharge with
                % corresponding wavelengths mp.F3.VortexCharge_lambdas
                % represents a chromatic vortex FPM
                charge = interp1(mp.F3.VortexCharge_lambdas,mp.F3.VortexCharge,lambda,'linear','extrap');
            end
            EP4 = propcustom_mft_Pup2Vortex2Pup( EP3, mp.F3.VortexCharge, mp.P1.compact.Nbeam/2, 0.3, 5, mp.useGPU );%--MFTs
        case{'splc','flc'}
            %--MFT from SP to FPM (i.e., P3 to F3)
            EF3inc = propcustom_mft_PtoF(EP3, mp.fl,lambda,mp.P2.compact.dx,mp.F3.compact.dxi,mp.F3.compact.Nxi,mp.F3.compact.deta,mp.F3.compact.Neta,mp.centering); %--E-field incident upon the FPM
            EF3 = mp.F3.compact.mask.amp.*EF3inc; % Apply FPM
            %--MFT from FPM to Lyot Plane (i.e., F3 to P4)
            EP4 = propcustom_mft_FtoP(EF3,mp.fl,lambda,mp.F3.compact.dxi,mp.F3.compact.deta,mp.P4.compact.dx,mp.P4.compact.Narr,mp.centering); %--E-field incident upon the Lyot stop 
        
        case{'lc,aplc','roddier'}
            %--MFT from SP to FPM (i.e., P3 to F3)
            EF3inc = propcustom_mft_PtoF(EP3, mp.fl,lambda,mp.P2.compact.dx,mp.F3.compact.dxi,mp.F3.compact.Nxi,mp.F3.compact.deta,mp.F3.compact.Neta,mp.centering); %--E-field incident upon the FPM
            %--Apply (1-FPM) for Babinet's principle later
            if(strcmp(mp.coro,'roddier'))
                FPM = mp.F3.compact.mask.amp.*exp(1i*2*pi/lambda*(mp.F3.n(lambda)-1)*mp.F3.t.*mp.F3.compact.mask.phzSupport);
                EF3 = (1-FPM).*EF3inc; %--Apply (1-FPM) for Babinet's principle later
            else
                EF3 = (1 - mp.F3.compact.mask.amp).*EF3inc;
            end
            %--Use Babinet's principle at the Lyot plane.
            EP4noFPM = propcustom_2FT(EP3,mp.centering); %--Propagate forward another pupil plane 
            EP4noFPM = padOrCropEven(EP4noFPM,mp.P4.compact.Narr); %--Crop down to the size of the Lyot stop opening
            %--MFT from FPM to Lyot Plane (i.e., F3 to P4)
            EP4sub = propcustom_mft_FtoP(EF3,mp.fl,lambda,mp.F3.compact.dxi,mp.F3.compact.deta,mp.P4.compact.dx,mp.P4.compact.Narr,mp.centering); % Subtrahend term for Babinet's principle     
            %--Babinet's principle at P4
            EP4 = (EP4noFPM-EP4sub);
            
        case{'hlc'}
            %--Complex transmission of the points outside the FPM (just fused silica with optional dielectric and no metal).
            t_Ti_base = 0;
            t_Ni_vec = 0;
            t_PMGI_vec = 1e-9*mp.t_diel_bias_nm; % [meters]
            pol = 2;
            [tCoef, ~] = falco_thin_film_material_def(lambda, mp.aoi, t_Ti_base, t_Ni_vec, t_PMGI_vec, lambda*mp.FPM.d0fac, pol);
            transOuterFPM = tCoef;
            %--Propagate to focal plane F3
            EF3inc = propcustom_mft_PtoF(EP3, mp.fl,lambda,mp.P2.compact.dx,mp.F3.compact.dxi,mp.F3.compact.Nxi,mp.F3.compact.deta,mp.F3.compact.Neta,mp.centering); %--E-field incident upon the FPM
            %--Apply (1-FPM) for Babinet's principle later
            EF3 = (transOuterFPM - mp.FPM.mask).*EF3inc; %- transOuterFPM instead of 1 because of the complex transmission of the glass as well as the arbitrary phase shift.
            %--Use Babinet's principle at the Lyot plane.
            EP4noFPM = propcustom_2FT(EP3,mp.centering); %--Propagate forward another pupil plane 
            EP4noFPM = padOrCropEven(EP4noFPM,mp.P4.compact.Narr); %--Crop down to the size of the Lyot stop opening
            EP4noFPM = transOuterFPM*EP4noFPM; %--Apply the phase and amplitude change from the FPM's outer complex transmission.
            %--MFT from FPM to Lyot Plane (i.e., F3 to P4)
            EP4sub = propcustom_mft_FtoP(EF3,mp.fl,lambda,mp.F3.compact.dxi,mp.F3.compact.deta,mp.P4.compact.dx,mp.P4.compact.Narr,mp.centering); % Subtrahend term for Babinet's principle     
            %--Babinet's principle at P4
            EP4 = (EP4noFPM-EP4sub); 
        
        case{'ehlc'}
            %--Complex transmission of the points outside the inner part of the FPM (just fused silica with optional dielectric and no metal).
            t_Ti_base = 0;
            t_Ni_vec = 0;
            t_PMGI_vec = 1e-9*mp.t_diel_bias_nm; % [meters]
            pol = 2;
            [tCoef, ~] = falco_thin_film_material_def(lambda, mp.aoi, t_Ti_base, t_Ni_vec, t_PMGI_vec, lambda*mp.FPM.d0fac, pol);
            transOuterFPM = tCoef;
            
            %--MFT from apodizer plane to FPM (i.e., P3 to F3)
            EF3inc = propcustom_mft_PtoF(EP3, mp.fl,lambda,mp.P2.compact.dx,mp.F3.compact.dxi,mp.F3.compact.Nxi,mp.F3.compact.deta,mp.F3.compact.Neta,mp.centering); %--E-field incident upon the FPM
            EF3 = FPM.*EF3inc; %--Apply FPM
            %--MFT from FPM to Lyot Plane (i.e., F3 to P4)
            EP4 = propcustom_mft_FtoP(EF3,mp.fl,lambda,mp.F3.compact.dxi,mp.F3.compact.deta,mp.P4.compact.dx,mp.P4.compact.Narr,mp.centering);
            
        case{'fohlc'}
            %--FPM representation (idealized as amplitude and phase)
            DM8amp = falco_gen_HLC_FPM_amplitude_from_cube(mp.dm8,'compact');
            DM8ampPad = padOrCropEven( DM8amp,Nfpm,'extrapval',1);
            DM9surf = falco_gen_HLC_FPM_surf_from_cube(mp.dm9,'compact');
            DM9surfPad = padOrCropEven( DM9surf,Nfpm);
            transOuterFPM = 1; %--Is 1 because normalized out in FOHLC model
            FPM = DM8ampPad.*exp(2*pi*1i/lambda*DM9surfPad);
            
            %--MFT from SP to FPM (i.e., P3 to F3)
            EF3inc = propcustom_mft_PtoF(EP3, mp.fl,lambda,mp.P2.compact.dx,mp.F3.compact.dxi,mp.F3.compact.Nxi,mp.F3.compact.deta,mp.F3.compact.Neta,mp.centering); %--E-field incident upon the FPM
            %--Apply (1-FPM) for Babinet's principle later
            EF3 = (1-FPM/transOuterFPM).*EF3inc; %- transOuterFPM instead of 1 because of the complex transmission of the glass as well as the arbitrary phase shift.
            %--Use Babinet's principle at the Lyot plane.
            EP4noFPM0 = propcustom_2FT(EP3,mp.centering); %--Propagate forward another pupil plane 
            EP4noFPM = padOrCropEven(EP4noFPM0,mp.P4.compact.Narr); %--Crop down to the size of the Lyot stop opening
            %--MFT from FPM to Lyot Plane (i.e., F3 to P4)
            EP4sub = propcustom_mft_FtoP(EF3,mp.fl,lambda,mp.F3.compact.dxi,mp.F3.compact.deta,mp.P4.compact.dx,mp.P4.compact.Narr,mp.centering); % Subtrahend term for Babinet's principle     
            %--Babinet's principle at P4
            EP4 = EP4noFPM - EP4sub; 

    end
end  

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%  Back to common propagation any coronagraph type   %%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%--Apply the Lyot stop
EP4 = mp.P4.compact.croppedMask.*padOrCropEven(EP4,mp.P4.compact.Narr);

% DFT to camera
EF4 = propcustom_mft_PtoF(EP4,mp.fl,lambda,mp.P4.compact.dx, dxi,Nxi,deta,Neta,  mp.centering);
% EF4 = propcustom_mft_PtoF(EP4,mp.fl,lambda,mp.P4.compact.dx,mp.F4.dxi,mp.F4.Nxi,mp.F4.deta,mp.F4.Neta); %--Code from before flagEval

%--Don't apply FPM if normalization value is being found
if(normFac==0)
    Eout = EF4; %--Don't normalize if normalization value is being found
else
    Eout = EF4/sqrt(normFac); %--Apply normalization
end


if(mp.useGPU)
    Eout = gather(Eout);
end



end % End of entire function


    
