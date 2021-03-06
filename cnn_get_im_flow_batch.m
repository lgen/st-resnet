function imo = cnn_get_im_flow_batch2(images, varargin)

opts.subTractFlow = 'off';
opts.nFramesPerVid = 1;
opts.numAugments = 1;
opts.frameSample = 'uniformly';
opts.flowDir = '';
opts.imageDir = '';
opts.temporalStride = 0;

opts.imageSize = [227, 227] ;
opts.border = [29, 29] ;
opts.averageImage = [] ;
opts.rgbVariance = [] ;
opts.augmentation = 'croponly' ;
opts.interpolation = 'bilinear' ;
opts.numAugments = 1 ;
opts.numThreads = 0 ;
opts.prefetch = false ;
opts.keepAspect = true;
opts.flowScales = [];
opts.cheapResize = 0;
opts.nFrameStack = 10;
opts.frameList = NaN;
opts.nFrames = [];
opts.subMedian = false;
opts.stretchAspect = 4/3 ;
opts.stretchScale = 1.2 ;
opts.fetchGPU = true ; 
[opts, varargin] = vl_argparse(opts, varargin);

flowDir = opts.flowDir;
imgDir = opts.imageDir;
% prefetch is used to load images in a separate thread
prefetch = opts.prefetch & isempty(opts.frameList);
fetchOpts= {'numThreads', opts.numThreads};
if opts.fetchGPU
  fetchOpts{end+1} = 'Gpu' ;
end

switch opts.augmentation
  case 'croponly'
    tfs = [.5 ; .5 ; 0 ];
  case 'f5'
    tfs = [...
      .5 0 0 1 1 .5 0 0 1 1 ;
      .5 0 1 0 1 .5 0 1 0 1 ;
       0 0 0 0 0  1 1 1 1 1] ;
  case 'f25'
    [tx,ty] = meshgrid(linspace(0,1,5)) ;
    tfs = [tx(:)' ; ty(:)' ; zeros(1,numel(tx))] ;
    tfs_ = tfs ;
    tfs_(3,:) = 1 ;
    tfs = [tfs,tfs_] ;
  case 'f25noCtr'
    [tx1,ty1] = meshgrid(linspace(.75,1,20)) ;
    [tx2,ty2] = meshgrid(linspace(0,.25,20)) ;
    tx = [tx1 tx2];     ty = [ty1 ty2];
    tfs = [tx(:)' ; ty(:)' ; zeros(1,numel(tx))] ;
    tfs_ = tfs ;
    tfs_(3,:) = 1 ;
    tfs = [tfs,tfs_] ;       
end

nStack = opts.imageSize(3);

if iscell(opts.frameList)
  im = vl_imreadjpeg(opts.frameList{1}, fetchOpts{:}) ; 
  sampled_frame_nr = opts.frameList{2};
else
  sampleFrameLeftRight = floor(nStack/4); % divide by 4 because of left,right,u,v
  frameOffsets = [-sampleFrameLeftRight:sampleFrameLeftRight-1]';

  frames = cell(numel(images), nStack, opts.nFramesPerVid);
  frames_rgb = cell(numel(images), 1, opts.nFramesPerVid);

  sampled_frame_nr = cell(numel(images),1);

  for i=1:numel(images)
    vid_name = images{i};
    nFrames = opts.nFrames(i);

    if  strcmp(opts.frameSample, 'uniformly')
      sampleRate = max(floor((nFrames-nStack/2)/opts.nFramesPerVid),1);
      frameSamples = nStack/4+1:sampleRate:nFrames - nStack/4 ;
      opts.temporalStride = sampleRate;
      frameSamples = vl_colsubset(nStack/4+1:nFrames-nStack/4, opts.nFramesPerVid, 'uniform') ;
      opts.temporalStride =  frameSamples(2) - frameSamples(1);
    elseif strcmp(opts.frameSample, 'temporalStride')
      frameSamples = nStack/4+1:opts.temporalStride:nFrames-nStack/4 ;
      if length(frameSamples) < opts.nFrameStack,
          frameSamples = round(linspace(nStack/4+1, nFrames - nStack/4, opts.nFramesPerVid)) ;
          opts.temporalStride = frameSamples(2) - frameSamples(1);
      end 
    elseif strcmp(opts.frameSample, 'random')
      frameSamples = randperm(nFrames-nStack/2)+nStack/4;
    elseif strcmp(opts.frameSample, 'temporalStrideRandom')
      frameSamples = nStack/4 +1:opts.temporalStride:nFrames - nStack/4 ;
      if length(frameSamples) < opts.nFrameStack,
          frameSamples = round(linspace(nStack/4+1, nFrames - nStack/4, opts.nFrameStack)) ;
          opts.temporalStride = frameSamples(2) - frameSamples(1);
      end 
    end 
    
    if length(frameSamples) < opts.nFramesPerVid,
        if length(frameSamples) > opts.nFrameStack
          frameSamples = frameSamples(1:length(frameSamples)-mod(length(frameSamples),opts.nFrameStack));
        end
        diff =  opts.nFramesPerVid - length(frameSamples);
        addFrames = 0;
        while diff > 0
          last_frame = min(frameSamples(end), max(nFrames - nStack/4 - opts.nFrameStack,nStack/4 )); 
          if mod(addFrames,2) % add to the front
            addSamples = nStack/4+1:opts.temporalStride:nFrames - nStack/4;
            addSamples = addSamples(1: length(addSamples) - mod(length(addSamples),opts.nFrameStack));
            if length(addSamples) > diff, addSamples = addSamples(1:diff); end
          else % add to the back
            addSamples = fliplr(nFrames - nStack/4 : -opts.temporalStride: nStack/4+1);           
            addSamples = addSamples(mod(length(addSamples),opts.nFrameStack)+1:length(addSamples));
            if length(addSamples) > diff, addSamples = addSamples(end-diff+1:end); end
          end

          if addFrames > 20
            addSamples = round(linspace(nStack/4+1, nFrames - nStack/4, opts.nFrameStack)) ;
          end
          frameSamples = [frameSamples addSamples]; 
          diff = opts.nFramesPerVid - length(frameSamples); 
          opts.temporalStride = max(ceil(opts.temporalStride-1), 1);
          addFrames = addFrames+1;

        end
    end
    if length(frameSamples) > opts.nFramesPerVid   
      if strcmp(opts.frameSample, 'temporalStride')
        s = fix((length(frameSamples)-opts.nFramesPerVid)/2);
      else % random
        s = randi(length(frameSamples)-opts.nFramesPerVid);
      end
        frameSamples = frameSamples(s+1:s+opts.nFramesPerVid);
    end

    for k = 1:opts.nFramesPerVid
        frames_rgb{i,1,k} = [vid_name 'frame' sprintf('%06d.jpg', frameSamples(k))] ;
    end 
    
      frameSamples =  repmat(frameSamples,nStack/2,1) +  repmat(frameOffsets,1,size(frameSamples,2));
      for k = 1:opts.nFramesPerVid
        for j = 1:nStack/2
            frames{i,(j-1)*2+1, k} = ['u' filesep vid_name 'frame' sprintf('%06d.jpg', frameSamples(j,k)) ] ;
            frames{i,(j-1)*2+2, k} = ['v' frames{i,(j-1)*2+1, k}(2:end)];
        end
      end

      sampled_frame_nr{i} = frameSamples;
  end
  
    if iscell(opts.imageDir)
          imgDir = opts.imageDir{i};
          flowDir = opts.flowDir{i};
    end

  frames_rgb = strcat([imgDir filesep], frames_rgb);
  if ~isempty(flowDir)
    frames = strcat([flowDir filesep], frames);
    frames = cat(2, frames, frames_rgb);
  else
    frames = frames_rgb;
  end
  if opts.numThreads > 0
    if prefetch
      vl_imreadjpeg(frames, fetchOpts{:}, 'prefetch') ;
      imo = {frames sampled_frame_nr}  ;
      return ;
    end
    im = vl_imreadjpeg(frames, fetchOpts{:} ) ;
  end

end

if strcmp(opts.augmentation, 'none')

  szw = cellfun(@(x) size(x,2),im);
  szh = cellfun(@(x) size(x,1),im);
  
  h_min = min(szh(:));
  w_min =  min(szw(:));
  sz = [h_min w_min] ;  
    
  sz = max(opts.imageSize(1:2), sz);
  sz = min(2*opts.imageSize(1:2), sz);

  scal = ([h_min w_min] ./ sz);

  imo =  zeros(sz(1), sz(2), opts.imageSize(3)+3, ...
            numel(images), 2 * opts.nFramesPerVid, 'single') ;
  if opts.fetchGPU
    imo = gpuArray(imo);
  end
  
  for i=1:numel(images)
    si = 1 ;
    for k = 1:opts.nFramesPerVid

      if numel(unique(szw)) > 1 || numel(unique(szh)) > 1
        for l=1:size(im,2)
            im{i,l,k} = im{i,l,k}(1:h_min,1:w_min,:);
        end
      end   
        imt = cat(3, im{i,:,k}) ;      


        if any(scal ~= 1)
          imo(:, :, :, i, si) = imresize(cat(3, im{i,:,k}),sz) ;
        else
          imo(:, :, :, i, si) = imt ; 
        end
        imt = [];
        imo(:, :, :, i, si+1) =  imo(:, end:-1:1, :, i, si);      
        imo(:, :, 1:2:nStack, i, si+1) = -imo(:, :, 1:2:nStack, i, si+1) + 255; %invert u if we flip   

        si = si + 2 ;

    end
  end  

  if opts.subMedian
    median_flow = median(imo(:,:,1:nStack),1);
    median_flow = median(median_flow,2);
    imo(:,:,1:nStack,:,:) = bsxfun(@minus, imo(:,:,1:nStack,:,:), median_flow ) ;
    imo(:,:,1:nStack,:,:) = bsxfun(@plus, imo(:,:,1:nStack,:,:), 128 ) ; 
  end
  
  if ~isempty(opts.averageImage)
    opts.averageImage = mean(mean(opts.averageImage,1),2) ;
    imo = bsxfun(@minus, imo,opts.averageImage) ;
  end
  return;
end


% augment now
if exist('tfs', 'var')
  [~,transformations] = sort(rand(size(tfs,2), numel(images)*opts.nFramesPerVid), 1) ;
end

imo = ( zeros(opts.imageSize(1), opts.imageSize(2), opts.imageSize(3)+3, ...
            numel(images), opts.numAugments * opts.nFramesPerVid, 'single') ) ;

if opts.fetchGPU
  imo = gpuArray(imo);
end

for i=1:numel(images)
  si = 1 ;
  
  szw = cellfun(@(x) size(x,2),im);
  szh = cellfun(@(x) size(x,1),im);  
  
  h_min = min(szh(:));
  w_min =  min(szw(:));
 
  
  if  strcmp( opts.augmentation, 'multiScaleRegular')
    reg_szs = [256, 224, 192, 168] ;          
    sz(1) = reg_szs(randi(4)); sz(2) = reg_szs(randi(4));
  elseif strcmp( opts.augmentation, 'stretch')
    aspect = exp((2*rand-1) * log(opts.stretchAspect)) ;
    scale = exp((2*rand-1) * log(opts.stretchScale)) ;
    tw = opts.imageSize(2) * sqrt(aspect) * scale ;
    th = opts.imageSize(1) / sqrt(aspect) * scale ;
    reduce = min([w_min / tw, h_min / th, 1]) ;
    sz = round(reduce * [th ; tw]) ;
  else
    sz = round(min(opts.imageSize(1:2)' .* (.75+0.5*rand(2,1)), [h_min; w_min])) ; % 0.75 +- 0.5, not keep aspect  
  end

  for k = 1:opts.nFramesPerVid
      
      if numel(unique(szw)) > 1 || numel(unique(szh)) > 1
        for l=1:size(im,2)
          im{i,l,k} = im{i,l,k}(1:h_min,1:w_min,:);
        end
      end
      
      imt = cat(3, im{i,:,k}) ;
      if opts.subMedian
          median_flow = median(imt(:,:,1:nStack),1);
          median_flow = median(median_flow,2);
          imt(:,:,1:nStack) = bsxfun(@minus, imt(:,:,1:nStack), median_flow ) ;
          imt(:,:,1:nStack) = bsxfun(@plus, imt(:,:,1:nStack), 128 ) ; 
      end
%       imt = gpuArray(imt);

    w = size(imt,2) ;
    h = size(imt,1) ;
    if ~strcmp(opts.augmentation, 'uniform')
      if ~isempty(opts.rgbVariance) % colour jittering only in training case
        offset = zeros(size(imt));
        offset = bsxfun(@minus, offset, reshape(opts.rgbVariance * randn(opts.imageSize(3),1), 1,1,opts.imageSize(3))) ;
        imt = bsxfun(@minus, imt, offset) ;
      end

      for ai = 1:opts.numAugments
        switch opts.augmentation
          case 'stretch'
            dx = randi(w - sz(2) + 1 ) ;
            dy = randi(h - sz(1) + 1 ) ;
            flip = rand > 0.5 ;
          case 'multiScaleRegular'
            dy = [0 h-sz(1) 0 h-sz(1)  floor((h-sz(1)+1)/2)] + 1; % 4 corners & centre
            dx = [0 w-sz(2) w-sz(2) 0 floor((w-sz(2)+1)/2)] + 1;
            corner = randi(5);
            dx = dx(corner); dy = dy(corner); % pick one corner of the image
            flip = rand > 0.5 ;  
          case 'f25noCtr'
            tf = tfs(:, transformations(mod(i+ai-1, numel(transformations)) + 1)) ;
            dx = floor((w - sz(2)) * tf(2)) + 1 ;
            dy = floor((h - sz(1)) * tf(1)) + 1 ;
            flip = tf(3) ;  
          otherwise
            sz = opts.imageSize(1:2) ;
            tf = tfs(:, transformations(mod(ai-1, numel(transformations)) + 1)) ;
            dx = floor((w - sz(2)) * tf(2)) + 1 ;
            dy = floor((h - sz(1)) * tf(1)) + 1 ;
            flip = tf(3) ;          
        end
        
        if opts.cheapResize
          sx = round(linspace(dx, sz(2)+dx-1, opts.imageSize(2))) ;
          sy = round(linspace(dy, sz(1)+dy-1, opts.imageSize(1))) ;
        else
          factor = [opts.imageSize(1)/sz(1) ...
              opts.imageSize(2)/sz(2)];
                   
          if any(abs(factor - 1) > 0.0001)
            imt =   imresize(imt(dy:sz(1)+dy-1,dx:sz(2)+dx-1,:), [opts.imageSize(1:2)]);
          end                   

          sx = 1:opts.imageSize(2); sy = 1:opts.imageSize(1);
        end
        
        if flip
          sx = fliplr(sx) ;
          imo(:,:,:,i,si) = imt(sy,sx,:) ;
          imo(:,:,1:2:nStack,i,si) = -imt(sy,sx,1:2:nStack) + 255; %invert u if we flip
        else
          imo(:,:,:,i,si) = imt(sy,sx,:) ;
        end

        si = si + 1 ;
      end
    else

      w = size(imt,2) ; h = size(imt,1) ;
      
      indices_y = [0 h-opts.imageSize(1)] + 1;
      indices_x = [0 w-opts.imageSize(2)] + 1;
      center_y = floor(indices_y(2) / 2)+1;
      center_x = floor(indices_x(2) / 2)+1;

      if opts.numAugments == 6,  indices_y = center_y;   
      elseif opts.numAugments == 2,  indices_x = [];   indices_y = [];  
      elseif opts.numAugments ~= 10, error('only 6 or 10 uniform crops allowed');  end
        for y = indices_y
        for x = indices_x
          imo(:, :, :, i, si) = ...
              imt(y:y+opts.imageSize(1)-1, x:x+opts.imageSize(2)-1, :);
                  
          imo(:, :, :, i, si+1) = imo(:, end:-1:1, :, i, si);          
          imo(:, :, 1:2:nStack, i, si+1) = -imo(:, end:-1:1, 1:2:nStack, i, si) + 255; %invert u if we flip

          si = si + 2 ;
        end
        end
        imo(:,:,:, i,si) = imt(center_y:center_y+opts.imageSize(1)-1,center_x:center_x+opts.imageSize(2)-1,:);
        
        imo(:,:,:, i,si+1) = imo(:, end:-1:1, :, i, si);        
        imo(:,:,1:2:nStack, i,si+1) = -imo(:, end:-1:1, 1:2:nStack, i, si) + 255; %invert u if we flip

        si = si + 2;
    end
  end
end


if ~isempty(opts.averageImage)
  imo = bsxfun(@minus, imo, opts.averageImage) ;
end

end
