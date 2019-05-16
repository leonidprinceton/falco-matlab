% Copyright 2019, by the California Institute of Technology. ALL RIGHTS
% RESERVED. United States Government Sponsorship acknowledged. Any
% commercial use must be negotiated with the Office of Technology Transfer
% at the California Institute of Technology.
% -------------------------------------------------------------------------
%
% Function to compute the table in InitialRawContrast.csv, which is used to  
% compute the flux ratio noise (FRN) for the WFIRST CGI.
%
% REVISION HISTORY:
% - Created by A.J. Riggs on 2019-05-15.
% -------------------------------------------------------------------------

function tableContrast = falco_FRN_InitialRawContrast(mp)
    
%--First 4 columns (the easy, bookkeeping parts of the table)
Nann = size(mp.eval.Rsens,1); %--Number of annuli
tableContrast = zeros(4*Nann,5);
tableContrast(:,1) = 0:(4*Nann-1); %--First column
tableContrast(2:2:end,2) = 1; %--Second column
tableContrast(1:2:end,3) = [(0:(Nann-1)).';(0:(Nann-1)).']; %--Third column, one half
tableContrast(2:2:end,3) = [(0:(Nann-1)).';(0:(Nann-1)).']; %--Third column, other half
tableContrast(2*Nann+1:end,4) = 1; %--Fourth Column

%% Get PSFs
%--Compute coherent-only image
mp.full.pol_conds = 10; %--Which polarization states to use when creating an image.
ImCoh = falco_get_summed_image(mp);

%--Compute coherent+incoherent light image
mp.full.pol_conds = [-2,-1,1,2]; %--Which polarization states to use when creating an image.
% ImBoth = falco_get_summed_image(mp);
mp.full.TTrms = 0; % [mas]
mp.full.Dstar = 1; % [mas]
mp.full.Dtel = 2.3631; % [meters]
mp.full.TipTiltNacross = 7; 
ImBoth = falco_get_summed_image_TipTiltPol(mp);

ImInco = ImBoth-ImCoh;
ImInco(ImInco<0) = 0;

if(mp.flagPlot)
    figure(81); imagesc(ImCoh); axis xy equal tight; colorbar; drawnow;
    figure(82); imagesc(ImBoth); axis xy equal tight; colorbar; drawnow;
    figure(83); imagesc(ImInco); axis xy equal tight; colorbar; drawnow;
end

%% Compute 2-D intensity-to-contrast map, and convert PSFs from NI to contrast
%  Compute at the center wavelength with the compact model
%  Compute for a quadrant and flip it twice to fill in all for quadrants.

%--Compute the (x,y) pairs in the image for each pixel
[XIS,ETAS] = meshgrid(mp.Fend.xisDL,mp.Fend.etasDL);

%--Pixels in Quadrant 1 and in the dark hole
maskBoolQuad1 = mp.Fend.corr.maskBool & XIS>=0 & ETAS>=0;
coords = [XIS(maskBoolQuad1),ETAS(maskBoolQuad1)]; %--(xi,eta) coordinates of those pixels [lambda0/D]
Nc = size(coords,1); %--Number of pixels
% figure(89); imagesc(maskBoolQuad1); axis xy equal tight; colorbar; drawnow;

%--Obtain the peak pixel value of an off-axis source centered at each pixel
%  in Quadrant 1 of the dark hole. Compute as a vector in order to use
%  parfor.
tic
peakVals = zeros(Nc,1);
if(mp.flagParfor)
    parfor ic = 1:Nc
        peakVals(ic) = falco_get_offset_peak(mp,coords,ic);
    end
else
   for ic = 1:Nc
        modvar.whichSource = 'offaxis';
        modvar.x_offset = coords(ic,1); 
        modvar.y_offset = coords(ic,2); 
        modvar.sbpIndex = mp.si_ref; 
        modvar.wpsbpIndex = mp.wi_ref;
        E2D = model_compact(mp, modvar);
        peakVals(ic) = max(abs(E2D(:)).^2);
    end  
end
fprintf('Time = %.2f s\n',toc)

%--Convert vector back into 2-D. Then fill in the other quadrants.
peak2D = zeros(size(ETAS));
peak2D(maskBoolQuad1) = peakVals;
peak2D(2:mp.Fend.Neta/2,:) = flipud(peak2D(mp.Fend.Neta/2+2:end,:)); %--Fill in Quadrant 4
peak2D(:,2:mp.Fend.Neta/2) = fliplr(peak2D(:,mp.Fend.Neta/2+2:end)); %--Fill in Quadrants 2 and 3

%--Compute the normalized matrix of contrast-to-normalized-intensity
CtoNI = peak2D/max(peakVals);
CtoNI(CtoNI==0) = 1e-10; %--To avoid dividing by zero.

%--Convert the PSFs from NI to contrast
Ccoh = ImCoh./CtoNI;
Cinco = ImInco./CtoNI;

if(mp.flagPlot)
    % figure(90); imagesc(mp.Fend.xisDL,mp.Fend.etasDL,peak2D); axis xy equal tight; colorbar; drawnow
    figure(91); imagesc(mp.Fend.xisDL,mp.Fend.etasDL,CtoNI); axis xy equal tight; colorbar; drawnow
    figure(181); imagesc(log10(Ccoh),[-10 -8]); axis xy equal tight; colorbar; drawnow;
    figure(183); imagesc(log10(Cinco),[-10 -8]); axis xy equal tight; colorbar; drawnow;
end

%% Compute the average contrast in each annulus (or annular segment)
CcohVec = zeros(Nann,1);
CincoVec = zeros(Nann,1);
rVec = zeros(Nann,1);

for ia=1:Nann        
    min_r = mp.eval.Rsens(ia,1);
    max_r = mp.eval.Rsens(ia,2);
    rVec(ia) = (min_r+max_r)/2;

    %--Compute the software mask for the scoring region
    maskScore.pixresFP = mp.Fend.res;
    maskScore.rhoInner = min_r; %--lambda0/D
    maskScore.rhoOuter = max_r; %--lambda0/D
    maskScore.angDeg = mp.Fend.score.ang; %--degrees
    maskScore.centering = mp.centering;
    maskScore.FOV = mp.Fend.FOV;
    maskScore.whichSide = mp.Fend.sides; %--which (sides) of the dark hole have open
    if(isfield(mp.Fend,'shape'));  maskScore.shape = mp.Fend.shape;  end
    [maskPartial,xis,etas] = falco_gen_SW_mask(maskScore);

    %--Compute the average intensity over the selected region
    CcohVec(ia) = sum(sum(maskPartial.*Ccoh))/sum(sum(maskPartial));
    CincoVec(ia) = sum(sum(maskPartial.*Cinco))/sum(sum(maskPartial));
    % figure(401); imagesc(maskPartial.*Ccoh); axis xy equal tight; colorbar; drawnow; pause(1);
end

if(mp.flagPlot)
    figure(411); semilogy(rVec,CcohVec,'-ko',rVec,CincoVec,':ko','Linewidth',3,'Markersize',8); 
    set(gca,'Fontsize',20); set(gcf,'Color','w');
    drawnow;
end
    
%% Fill in Column 5 of the table

%--Coherent component
tableContrast(1:2:2*Nann,5) = 2*CcohVec; %--Coherent, MUF=2xCoherent
tableContrast(2*Nann+1:2:end,5) = CcohVec; %--Coherent, no MUF

%--NOTICE: UNKNOWN YET WHETHER THE "incoherent" PART OF THE TABLE INCLUDES
%THE COHERENT PART TOO, AND HOW MUFs ARE IMPLEMENTED.
%--Incoherent
tableContrast(2:2:2*Nann,5) = 2*(CincoVec-CcohVec); %--Incoherent x 2, MUFs of 2 ???????? %--NEED TO FIND OUT HOW MUFS ARE CALCULATED BY BRIAN. THIS IS A PLACEHOLDER
tableContrast(2*Nann+2:2:end,5) = CincoVec-CcohVec; %--Incoherent, no MUF




end %--END OF FUNCTION


%% Extra function needed to use parfor because parfor requires linear indexing
function peakVal = falco_get_offset_peak(mp,coords,ic)
    
    modvar.whichSource = 'offaxis';
    modvar.x_offset = coords(ic,1); 
    modvar.y_offset = coords(ic,2); 
    modvar.sbpIndex = mp.si_ref; 
    modvar.wpsbpIndex = mp.wi_ref;
    E2D = model_compact(mp, modvar);
    peakVal = max(abs(E2D(:)).^2);
    
end

%%
% % Function to get a simulated image from the full model at the specified
% % wavelength, polarization state, and tip/tilt offset
% %
% % ---------------
% % INPUTS:
% % - ic = index in list of combinations
% % - inds_list = list of indices for the combinations
% % - offsets = list of (x,y) offsets of the PSF [lambda0/D]
% % - mp = structure of model parameters
% %
% % OUTPUTS
% % - Iout: simulated image from full model at one wavelength and polarization
% %
% % REVISION HISTORY
% % - Modified on 2019-05-15 by A.J. Riggs from falco_get_single_sim_image to
% % falco_get_single_sim_image_LamPolTT
% % - Created on 2019-05-06 by A.J. Riggs.
% 
% function Iout = falco_get_single_sim_image_LamPolTT(ic,inds_list,offsets,mp)
% 
% %--Get the starlight image
% modvar.sbpIndex   = mp.full.indsLambdaMat(mp.full.indsLambdaUnique(inds_list(1,ic)),1);
% modvar.wpsbpIndex = mp.full.indsLambdaMat(mp.full.indsLambdaUnique(inds_list(1,ic)),2);
% mp.full.polaxis = mp.full.pol_conds(inds_list(2,ic));
% modvar.whichSource = 'offset';
% modvar.x_offset = offsets(inds_list(3,ic),1);
% modvar.y_offset = offsets(inds_list(3,ic),2);
% Estar = model_full(mp, modvar);
% Iout = (abs(Estar).^2); %--Apply spectral weighting outside this function
% 
% % %--Optionally include the planet PSF
% % if(mp.planetFlag)
% %     modvar.whichSource = 'exoplanet';
% %     Eplanet = model_full(mp,modvar);
% %     Iout = Iout + abs(Eplanet).^2; %--Apply spectral weighting outside this function
% % end
%     
% end %--END OF FUNCTION