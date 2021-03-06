%% Simulation Map
% Script to generate simulated map of bird migration

%% Clear and load data
clear all; 
load('../1-Cleaning/data/dc_corr.mat'); 
load('./data/Flight_inference.mat'); 
load('./data/Flight_estimationMap','g');
load coastlines;
addpath('./functions/'); 

dclat = [dc.lat]';
dclon = [dc.lon]';


%% Compute neighborhood, weight and variance 

% Generation of the path
mask_total = g.mask_day & repmat(g.latlonmask,1,1,g.nt);
ndc = numel(dc);

Pathll=cell(1,g.nat);
pathll=cell(1,g.nat);
ndt=cell(1,g.nat);
tic  %3min not-parr because of ismember (lin 220)
for i_d=1:g.nat
    ndt{i_d}=sum(g.dateradar==i_d);
    [LAT,LON,DT]= ndgrid(1:g.nlat,1:g.nlon,1:ndt{i_d});

    Path=Inf*ones(g.nlat,g.nlon,ndt{i_d});
    Path(mask_total(:,:,g.dateradar==i_d))=nan;
    path = nan(sum(isnan(Path(:))),1);
    
    slat = 1:ceil(log(g.nlat+1)/log(2));
    slon = 1:ceil(log(g.nlon+1)/log(2));
    sat = 1:ceil(log(ndt{i_d}+1)/log(2));
    sn = max([numel(slat), numel(slon) numel(sat)]);
    nb = nan(sn,1);
    start = zeros(sn+1,1);
    ds = 2.^(sn-1:-1:0);
    for i_scale = 1:sn
        [LAT_s,LON_s,DT_s] = ndgrid(1:ds(i_scale):g.nlat,1:ds(i_scale):g.nlon,1:ds(i_scale):ndt{i_d}); % matrix coordinate
        id = find(isnan(Path(:)));
        id = id(ismember([LAT(id) LON(id) DT(id)], [LAT_s(:) LON_s(:) DT_s(:)], 'rows'));
        nb(i_scale) = numel(id);
        start(i_scale+1) = start(i_scale)+nb(i_scale);
        path( start(i_scale)+(1:nb(i_scale)) ) = id(randperm(nb(i_scale)));
        Path(path( start(i_scale)+(1:nb(i_scale)) )) = start(i_scale)+(1:nb(i_scale));
    end

    Pathll{i_d}=reshape(Path(repmat(g.latlonmask,1,1,ndt{i_d})),g.nlm,ndt{i_d});
    [~,pathll{i_d}] = sort(Pathll{i_d}(:));
    pathll{i_d}=pathll{i_d}(~isinf(Pathll{i_d}(pathll{i_d})));
    
    Pathll{i_d}= int64(Pathll{i_d});
    pathll{i_d}= int64(pathll{i_d});
end
toc

% Distance Matrix common to all day
Ddist_gg = squareform(pdist([g.lat2D(g.latlonmask) g.lon2D(g.latlonmask)], @lldistkm));
Ddist_gr = pdist2([[dc.lat]' [dc.lon]'], [g.lat2D(g.latlonmask) g.lon2D(g.latlonmask)], @lldistkm);


% Covariance Matrix of hard data
Dtime = squareform(pdist(data.time));
Ddist_sm = squareform(pdist([dclat dclon], @lldistkm));
Ddist = Ddist_sm(data.radar,data.radar);

tic;Crrnu = uv.cov.Cu(Ddist,Dtime);toc
tic;Crrnv = uv.cov.Cv(Ddist,Dtime);toc


%%
% 2.2 Residu: Computaiton of the weight neigh and S
NEIGHG=cell(g.nat,1);
NEIGHR=cell(g.nat,1);
LAMBDA_u=cell(g.nat,1);
LAMBDA_v=cell(g.nat,1);
S_u=cell(g.nat,1);
S_v=cell(g.nat,1);

dist_thr_g = 500;
time_thr_g = 0.4;
dist_thr_r = 2000;
time_thr_r = 2;
neighg_nb=100;
neighr_nb=50;


for i_d=1:g.nat
    % Sub-selection of the day radar and grid
    neighday{i_d}  = find(data.day==i_d);
    uv_cov_C_u_i_d = Crrnu(neighday{i_d},neighday{i_d});
    uv_cov_C_v_i_d = Crrnv(neighday{i_d},neighday{i_d});
    uv_ut{i_d} =  uv.ut(neighday{i_d});
    uv_vt{i_d} =  uv.vt(neighday{i_d});
    sim{i_d} = find(g.dateradar==i_d);
    
    % Distance matrix for the day
    Dtime_gg = squareform(pdist(datenum(g.time(sim{i_d}))'));
    Dtime_gr = pdist2(data.time(neighday{i_d}), datenum(g.time(sim{i_d}))');
    
    % 4. Initizialization of the kriging weights and variance error
    NEIGHG_tmp = nan(neighg_nb,numel(pathll{i_d}));
    NEIGHR_tmp = nan(neighr_nb,numel(pathll{i_d}));
    LAMBDA_u_tmp = nan(neighg_nb+neighr_nb,numel(pathll{i_d}));
    LAMBDA_v_tmp = nan(neighg_nb+neighr_nb,numel(pathll{i_d}));
    S_u_tmp = nan(numel(pathll{i_d}),1);
    S_v_tmp = nan(numel(pathll{i_d}),1);
    tmp_u = repmat((1:g.nlm)',1,ndt{i_d});
    LL_i=tmp_u(pathll{i_d});
    tmp_u = repmat(1:ndt{i_d},g.nlm,1);
    TT_i=tmp_u(pathll{i_d});
    Pathll_i_d = Pathll{i_d};
    neighday_i_d = neighday{i_d};
    
    % 5 Loop of scale for multi-grid path
    tic
    parfor i_pt = 1:numel(pathll{i_d})
        
        % 1. Neighbor from grid
        % Find in the index of the path such that the spatio-temporal distance
        % is within wradius. Then, only select the already simulated value
        % (path value less than currently simulated)
        neighg = find(Pathll_i_d<i_pt & bsxfun(@and, Ddist_gg(:,LL_i(i_pt))<dist_thr_g , Dtime_gg(:,TT_i(i_pt))'<time_thr_g ));
        
        Cgp_u = uv.cov.Cu( Ddist_gg(LL_i(Pathll_i_d(neighg)),LL_i(i_pt)), Dtime_gg(TT_i(Pathll_i_d(neighg)),TT_i(i_pt)) );
        [Cgp_u,tmp_u]=maxk(Cgp_u,neighg_nb);
        neighg=neighg(tmp_u);
        Cgp_v = uv.cov.Cv(Ddist_gg(LL_i(Pathll_i_d(neighg)),LL_i(i_pt)), Dtime_gg(TT_i(Pathll_i_d(neighg)),TT_i(i_pt)));
        
        Cgg_u = uv.cov.Cu(Ddist_gg(LL_i(Pathll_i_d(neighg)),LL_i(Pathll_i_d(neighg))), Dtime_gg(TT_i(Pathll_i_d(neighg)),TT_i(Pathll_i_d(neighg))));
        Cgg_v = uv.cov.Cv(Ddist_gg(LL_i(Pathll_i_d(neighg)),LL_i(Pathll_i_d(neighg))), Dtime_gg(TT_i(Pathll_i_d(neighg)),TT_i(Pathll_i_d(neighg))));

        
        % 2. Find the radar neigh
        neighr=find( Ddist_gr(data.radar(neighday_i_d),LL_i(i_pt))<dist_thr_r & Dtime_gr(:,TT_i(i_pt))<time_thr_r);
        Crp_u = uv.cov.Cu(Ddist_gr(data.radar(neighday_i_d(neighr)),LL_i(i_pt)), Dtime_gr(neighr,TT_i(i_pt)));
        [Crp_u,tmp_u]=maxk(Crp_u,neighr_nb);
        neighr=neighr(tmp_u);
        Crp_v = uv.cov.Cv(Ddist_gr(data.radar(neighday_i_d(neighr)),LL_i(i_pt)), Dtime_gr(neighr,TT_i(i_pt)));
        
        Crr_u = uv_cov_C_u_i_d(neighr,neighr);
        Crr_v = uv_cov_C_v_i_d(neighr,neighr);
        Crg_u = uv.cov.Cu(Ddist_gr(data.radar(neighday_i_d(neighr)),LL_i(Pathll_i_d(neighg))), Dtime_gr(neighr,TT_i(Pathll_i_d(neighg))));
        Crg_v = uv.cov.Cv(Ddist_gr(data.radar(neighday_i_d(neighr)),LL_i(Pathll_i_d(neighg))), Dtime_gr(neighr,TT_i(Pathll_i_d(neighg))));
        
        l_u =  [Cgg_u Crg_u'; Crg_u Crr_u] \  [Cgp_u; Crp_u];
        l_v =  [Cgg_v Crg_v'; Crg_v Crr_v] \  [Cgp_v; Crp_v];
        
        NEIGHG_tmp(:,i_pt) = [neighg ; nan(neighg_nb-numel(neighg),1)];
        NEIGHR_tmp(:,i_pt) = [neighr ; nan(neighr_nb-numel(neighr),1)];
        
        LAMBDA_u_tmp(:,i_pt) = [l_u ; nan(neighr_nb+neighg_nb-numel(l_u),1)]';
        LAMBDA_v_tmp(:,i_pt) = [l_v ; nan(neighr_nb+neighg_nb-numel(l_v),1)]';
        S_u_tmp(i_pt) = sqrt(sum( uv.cov.parm_u(1:2)) - l_u'*[Cgp_u; Crp_u]);
        S_v_tmp(i_pt) = sqrt(sum( uv.cov.parm_v(1:2)) - l_v'*[Cgp_v; Crp_v]);
        assert(isreal(S_v_tmp(i_pt)))
    end
    
    NEIGHG{i_d} = single(NEIGHG_tmp);
    NEIGHR{i_d} = single(NEIGHR_tmp);
    LAMBDA_u{i_d} = single(LAMBDA_u_tmp);
    LAMBDA_v{i_d} = single(LAMBDA_v_tmp);
    S_u{i_d} = single(S_u_tmp);
    S_v{i_d} = single(S_v_tmp);
    
%     dlmwrite(['data/sim_flight_NEIGHG_' num2str(i_d)],NEIGHG{i_d})
%     dlmwrite(['data/sim_flight_NEIGHR_' num2str(i_d)],NEIGHR{i_d})
%     dlmwrite(['data/sim_flight_LAMBDA_u_' num2str(i_d)],LAMBDA_u{i_d})
%     dlmwrite(['data/sim_flight_LAMBDA_v_' num2str(i_d)],LAMBDA_v{i_d})
%     dlmwrite(['data/sim_flight_S_u_' num2str(i_d)],S_u{i_d})
%     dlmwrite(['data/sim_flight_S_v_' num2str(i_d)],S_v{i_d})    
    toc
    
end



% save('data/Flight_simulationMap','NEIGHG','NEIGHR','LAMBDA_u','LAMBDA_v','pathll','S_u','S_v','neighday','sim','-v7.3')
% load('data/Flight_simulationMap')

%% 2.2 Generation of realizations
%load('data/Density_simulationMap_residu')

[latmask, lonmask]=ind2sub([g.nlat g.nlon],find(g.latlonmask));

nb_real = 100; 
real_un_ll = nan(g.nlm,g.nt,nb_real);
real_vn_ll = nan(g.nlm,g.nt,nb_real);


for radareal=1:nb_real
    rng('shuffle');
    Uu=randn(g.nlm,g.nt);
    Uv=randn(g.nlm,g.nt);
    
    for i_d=1:g.nat
        
        tmp_u = nan(g.nlm,numel(sim{i_d}));
        tmp_v = nan(g.nlm,numel(sim{i_d}));
    
        for i_pt = 1:numel(pathll{i_d})
            ng = ~isnan(NEIGHG{i_d}(:,i_pt));
            nr = ~isnan(NEIGHR{i_d}(:,i_pt));
            nl = ~isnan(LAMBDA_u{i_d}(:,i_pt));
            tmp_u(pathll{i_d}(i_pt)) = LAMBDA_u{i_d}(nl,i_pt)'*[tmp_u(NEIGHG{i_d}(ng,i_pt)) ; uv.ut(neighday{i_d}(NEIGHR{i_d}(nr,i_pt)))] + Uu(i_pt)*S_u{i_d}(i_pt);
            tmp_v(pathll{i_d}(i_pt)) = LAMBDA_v{i_d}(nl,i_pt)'*[tmp_v(NEIGHG{i_d}(ng,i_pt)) ; uv.vt(neighday{i_d}(NEIGHR{i_d}(nr,i_pt)))] + Uu(i_pt)*S_v{i_d}(i_pt);
            %assert(~isnan(Resd(pathll{i_d}(i_pt))))
            %assert(isreal(Resd(pathll{i_d}(i_pt))))
        end
        
        real_un_ll(:,sim{i_d},radareal) = tmp_u;
        real_vn_ll(:,sim{i_d},radareal) = tmp_v;
        
    end
end

real_u_ll = single(real_un_ll *uv.trans.std(1) + uv.trans.mean(1));
real_v_ll = single(real_vn_ll *uv.trans.std(2) + uv.trans.mean(2));


save('data/Flight_simulationMap_real_ll','real_u_ll','real_v_ll','-v7.3');

%% Figure
radareal=1;

u = nan(g.nlat,g.nlon,g.nt);
v = nan(g.nlat,g.nlon,g.nt);
u(repmat(g.latlonmask,1,1,g.nt)) = real_u_ll(:,:,radareal);
v(repmat(g.latlonmask,1,1,g.nt)) = real_v_ll(:,:,radareal);

u(isnan(u))=0;
v(isnan(v))=0;

rzd=1/4;
lat2D_res=imresize(g.lat2D,rzd);
lon2D_res=imresize(g.lon2D,rzd);

h=figure(2);  
worldmap([min(g.lat) max(g.lat)], [min(g.lon) max(g.lon)]);  
filename='data/Flight_simulationMap';
mask_fullday = find(~reshape(all(all(isnan(guv.u_est),1),2),g.nt,1));
Frame(numel(mask_fullday)-1) = struct('cdata',[],'colormap',[]); 
geoshow('landareas.shp', 'FaceColor', [0.5 0.7 0.5])
geoshow('worldrivers.shp','Color', 'blue')
set(gcf,'color','w');

for i_t = 1:numel(mask_fullday)

    u_res = imresize(u(:,:,mask_fullday(i_t)),rzd);
    u_isnan_res = imresize(u_isnan(:,:,mask_fullday(i_t)),rzd);
    u_res=u_res./u_isnan_res;
    u_res(u_isnan_res<0.5)=nan;

    v_res = imresize(v(:,:,mask_fullday(i_t)),rzd);
    v_isnan_res = imresize(v_isnan(:,:,mask_fullday(i_t)),rzd);
    v_res=v_res./v_isnan_res;
    v_res(v_isnan_res<0.5)=nan;
    
    hsurf=quiverm(lat2D_res,lon2D_res,u_res,v_res,'k');
    
    drawnow
    title(datestr(g.time(mask_fullday(i_t)))); drawnow;
    Frame(i_t) = getframe(h);
    [imind,cm] = rgb2ind(frame2im(Frame(i_t)),256); 
    if i_t == 1
        imwrite(imind,cm,[filename '.gif'],'gif', 'Loopcount',inf,'DelayTime',0.1);
    else
        imwrite(imind,cm,[filename '.gif'],'gif','WriteMode','append','DelayTime',0.1);
    end
    delete(hsurf);
end

v=VideoWriter([filename '.avi']);
v.FrameRate = 4;
v.Quality = 75;
open(v);
writeVideo(v, Frame);
close(v);

