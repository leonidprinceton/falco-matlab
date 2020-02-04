% Copyright 2018, 2019, by the California Institute of Technology. ALL RIGHTS
% RESERVED. United States Government Sponsorship acknowledged. Any
% commercial use must be negotiated with the Office of Technology Transfer
% at the California Institute of Technology.
% -------------------------------------------------------------------------
%
%--Script to perform an HLC design run.
%  1) Load the default model parameters for an HLC.
%  2) Specify the values to overwrite.
%  3) Run a single trial of WFC using FALCO.
%
% REVISION HISTORY:
% --------------
% Modified on 2019-02-26 by A.J. Riggs to load the defaults first.
% ---------------

clear all;


%% Step 1: Define Necessary Paths on Your Computer System

%--Functions for when the full model uses PROPER
addpath('~/Repos/proper-models/wfirst_cgi/models_phaseb/matlab');
addpath('~/Repos/proper-models/wfirst_cgi/models_phaseb/matlab/examples');

%--Library locations. FALCO and PROPER are required. CVX is optional.
mp.path.falco = '~/Repos/falco-matlab/';  %--Location of FALCO
mp.path.proper = '~/Documents/MATLAB/PROPER/'; %--Location of the MATLAB PROPER library

%%--Output Data Directories (Comment these lines out to use defaults within falco-matlab/data/ directory.)
mp.path.config = '~/Repos/falco-matlab/data/brief/'; %--Location of config files and minimal output files. Default is [mainPath filesep 'data' filesep 'brief' filesep]
mp.path.ws = '~/Repos/falco-matlab/data/ws/'; % (Mostly) complete workspace from end of trial. Default is [mainPath filesep 'data' filesep 'ws' filesep];

%%--Add to the MATLAB Path
addpath(genpath(mp.path.falco)) %--Add FALCO library to MATLAB path
addpath(genpath(mp.path.proper)) %--Add PROPER library to MATLAB path


%% Step 2: Load default model parameters

EXAMPLE_defaults_WFIRST_PhaseB_PROPER_SPC_Spec_custom

%% Step 3a: Overwrite default values as desired

% %%--Special Computational Settings
mp.flagParfor = true; %--whether to use parfor for Jacobian calculation
mp.flagPlot = true;
% mp.propMethodPTP = 'mft';

%--Record Keeping
mp.SeriesNum = 49;
mp.TrialNum = 4;

%%--[OPTIONAL] Start from a previous FALCO trial's DM settings
% fn_prev = 'Series...snippet.mat';
% temp = load(fn_prev,'out');
% mp.dm1.V = temp.out.DM1V;
% mp.dm2.V = temp.out.DM2V;
% clear temp

% %--DEBUGGING:
% mp.fracBW = 0.01;       %--fractional bandwidth of the whole bandpass (Delta lambda / lambda0)
% mp.Nsbp = 1;            %--Number of sub-bandpasses to divide the whole bandpass into for estimation and control
% mp.Nwpsbp = 1;          %--Number of wavelengths to used to approximate an image in each sub-bandpass
% % mp.flagParfor = false; %--whether to use parfor for Jacobian calculation
% mp.full.pol_conds = 10;

%% Step 3b: Obtain the phase retrieval phase.

mp.full.input_field_rootname = '/Users/ajriggs/Repos/falco-matlab/data/maps/input_full';
optval = mp.full;
optval.source_x_offset =0;
optval.zindex = 4;
optval.zval_m = 0.19e-9;
optval.dm1_m = mp.full.dm1.flatmap;
optval.use_dm1 = 1;
optval.end_at_fpm_exit_pupil = 1;
optval.output_field_rootname = [fileparts(mp.full.input_field_rootname) filesep 'fld_at_xtPup'];
optval.use_fpm = 0;
optval.use_hlc_dm_patterns = 0;
nout = 1024; %512; 			% nout > pupil_daim_pix
optval.output_dim = 1024;%% Get the Input Pupil's E-field

if(mp.Nsbp==1)
    lambdaFacs = 1;
else
    lambdaFacs = linspace(1-mp.fracBW/2,1+mp.fracBW/2,mp.Nsbp);
end

mp.P1.compact.E = ones(mp.P1.compact.Nbeam+2,mp.P1.compact.Nbeam+2,mp.Nsbp); %--Initialize
for si=1:mp.Nsbp
    lambda_um = 1e6*mp.lambda0*lambdaFacs(si);

    fldFull = prop_run('model_full_wfirst_phaseb', lambda_um, nout, 'quiet', 'passvalue',optval );
    if(mp.flagPlot)
        figure(605); imagesc(angle(fldFull)); axis xy equal tight; colorbar; colormap hsv;
        figure(606); imagesc(abs(fldFull)); axis xy equal tight; colorbar; colormap parula;
    end

    lams = num2str(lambda_um, '%6.4f');
    polaxis = optval.polaxis;
    pols = ['polaxis'  num2str(polaxis,2)];
    fitswrite(real(fldFull), [mp.full.input_field_rootname '_' lams 'um_' pols '_real.fits' ]);
    fitswrite(imag(fldFull), [mp.full.input_field_rootname '_' lams 'um_' pols '_imag.fits' ]);

    %%--Downsampling for the compact model
    dxF = 1;
    dxC = mp.P1.full.Nbeam/mp.P1.compact.Nbeam;
    Nf = length(fldFull); %--N full
    Nc = ceil_even( (mp.P1.compact.Nbeam/mp.P1.full.Nbeam)*Nf ); %--N compact
    xF = (-Nf/2:Nf/2-1)*dxF;
    xC = (-Nc/2:Nc/2-1)*dxC;
    [Xf,Yf] = meshgrid(xF);
    [Xc,Yc] = meshgrid(xC);
    fldC = interp2(Xf,Yf,fldFull,Xc,Yc,'cubic',0); %--Downsample by interpolation
    fldC = padOrCropEven(fldC,ceil_even(mp.P1.compact.Nbeam+1));
    if(mp.flagPlot)
        figure(607); imagesc(abs(fldC)); axis xy equal tight; colorbar; colormap parula;
        figure(608+si-1); imagesc(angle(fldC)); axis xy equal tight; colorbar; colormap hsv;
    end

    %--Assign to initial E-field in compact model.
    temp = 0*fldC;
    temp(2:end,2:end) = rot90(fldC(2:end,2:end),2);
    mp.P1.compact.E(:,:,si) = temp;
    
end

%% Step 4: Generate the label associated with this trial

mp.runLabel = ['Series',num2str(mp.SeriesNum,'%04d'),'_Trial',num2str(mp.TrialNum,'%04d_'),...
    mp.coro,'_',mp.whichPupil,'_',num2str(numel(mp.dm_ind)),'DM',num2str(mp.dm1.Nact),'_z',num2str(mp.d_dm1_dm2),...
    '_IWA',num2str(mp.Fend.corr.Rin),'_OWA',num2str(mp.Fend.corr.Rout),...
    '_',num2str(mp.Nsbp),'lams',num2str(round(1e9*mp.lambda0)),'nm_BW',num2str(mp.fracBW*100),...
    '_',mp.controller];

%% Step 5: Perform the Wavefront Sensing and Control

out = falco_wfsc_loop(mp);


%%
return
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% FLUX RATIO NOISE (FRN) ANALYSIS SECTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%--Data locations for WFIRST CGI calculations of flux ratio noise (FRN)
mp.path.frn_coro = '~/Downloads/CGdata/'; %--Location of coronagraph performance data tables. Needs slash at end.
fn_prefix = sprintf('s%04dt%04d_',mp.SeriesNum,mp.TrialNum);

%% Change the resolution

E0 = mp.P1.compact.E; %--Don't erase the starting settings.
paths = mp.path;
runLabel = mp.runLabel;
sn = mp.SeriesNum;
tn = mp.TrialNum;
clear mp
mp.runLabel = runLabel;
mp.P1.compact.E = E0; 
mp.path = paths;

%--Re-initialize mp structure
EXAMPLE_defaults_WFIRST_PhaseB_PROPER_SPC_Spec_custom %--Load default model parameters

mp.SeriesNum = sn;
mp.TrialNum = tn;

mp.Fend.res = 5; %--Change the image resolution [pixels per lambda0/D]
mp.full.output_dim = ceil_even(1 + mp.Fend.res*(2*mp.Fend.FOV)); %  dimensions of output in pixels (overrides output_dim0)
mp.full.final_sampling_lam0 = 1/mp.Fend.res;	%   final sampling in lambda0/D

%--Set DM commands back to final
mp.dm1.V = out.dm1.Vall(:,:,end);
mp.dm2.V = out.dm2.Vall(:,:,end);

%--Save the config file
fn_config = [mp.path.config mp.runLabel,'_configHD.mat'];
save(fn_config)
fprintf('Saved the config file: \t%s\n',fn_config)
%--Get configuration data from a function file
[mp,out] = falco_init_ws(fn_config);


%% Compute the table of annular zones

mp.eval.Rsens = ...
                [3., 4.;...
                4., 5.;...
                5., 6.;...
                6., 7.;...
                7., 8.]; 
            
tableAnn = falco_FRN_AnnularZone_table(mp);
writetable(tableAnn,[mp.path.frn_coro, fn_prefix, 'AnnZoneList.csv']); %--Save to CSV file
tableAnn  


%% Compute the table InitialRawContrast.csv

[tableContrast, tableCtoNI,data] = falco_FRN_InitialRawContrast(mp);
writetable(tableContrast,[mp.path.frn_coro, fn_prefix, 'InitialRawContrast.csv']); %--Save to CSV file
writetable(tableCtoNI,[mp.path.frn_coro, fn_prefix, 'NItoContrast.csv']); %--Save to CSV file
save([mp.path.frn_coro, fn_prefix, 'c_data.mat'],'data') %--Save 2-D and 1-D Contrast and CtoNI map for making plots later
tableContrast
tableCtoNI


%% Compute the Krist table

%--Other constants
mp.yield.Dtel = 2.3631; % meters

%--Define radial sampling and range
mp.yield.R0 = 2.5;
mp.yield.R1 = 9.1;

%--Compute and save the table
tableKrist = falco_FRN_Krist_table(mp);
writetable(tableKrist,[mp.path.frn_coro, fn_prefix, 'KristTable.csv']); %--Save to CSV file

%--Plot the table data
matKrist = tableKrist{:,:};
figure(200); imagesc(matKrist); axis tight;
figure(201); imagesc(log10(matKrist)); axis tight;
figure(202); semilogy(matKrist(:,1),matKrist(:,3),'-b',matKrist(:,1),matKrist(:,4),'-r','Linewidth',3); %--Compare intensity and contrast plots


%% Calculate Sensitivities.csv 

%--Rows 1 to 10: Z2 to Z11 sensitivities to 1nm RMS of Zernike phase aberrations at entrance pupil.
%--Rows 11 to 17: Gain Z5 to Z11 sensitivities
%--Row 18: Pupil X shear
%--Row 19: Pupil Y shear
%--Row 20: DM Settling
%--Row 21: DM Thermal

tableSens = falco_FRN_Sens_table(mp);
writetable(tableSens,[mp.path.frn_coro, fn_prefix, 'Sensitivities.csv']); %--Save to CSV file
tableSens

