%{
psy.MovingNoiseLookup (lookup) # cached noise maps to save computation time
moving_noise_version           : smallint                      # algorithm version; increment when code changes
moving_noise_paramhash         : char(10)                      # hash of the lookup parameters
---
params            : blob   # cell array of params
cached_movie                : longblob                      # [y,x,frames]
moving_noise_lookup_ts=CURRENT_TIMESTAMP: timestamp            # automatic
%}

classdef MovingNoiseLookup < dj.Relvar
    properties(Constant)
        table = dj.Table('psy.MovingNoiseLookup')
    end
    
    methods
        function [m, key] = lookup(self, cond, degxy, fps)
            % make noise stimulus movie  and update condition
            % INPUTS:
            %   cond  - condition parameters
            %   degxy - visual degrees across x and y
            %   fps   - frames per second
            
            key.moving_noise_version = 1;  % increment if you make any changes to the code below
            
            params = {cond degxy fps};
            hash = dj.DataHash(params);
            key.moving_noise_paramhash = hash(1:10);
            
            if count(psy.MovingNoiseLookup & key)
                m = fetch1(self & key, 'cached_movie');
            else
                % create gaussian movie
                r = RandStream.create('mt19937ar','NormalTransform', ...
                    'Ziggurat', 'Seed', cond.rng_seed);
                period = cond.ori_on_secs + cond.ori_off_secs;
                duration = cond.n_dirs * period;
                nFrames = round(duration*fps/2)*2;
                sz = [cond.tex_ydim, cond.tex_xdim, nFrames];
                assert(~any(bitand(sz,1)), 'all movie dimensions must be even')
                m = r.randn(sz);  % movie
                
                % apply temporal filter in time domain
                % Use hamming filter for most compact kernel
                semi = round(fps/cond.temp_bandwidth);
                k = hamming(semi*2+1);
                k = k/sum(k);
                m = convn(m, permute(k, [3 2 1]), 'same');
                
                % apply spatial filter in frequency space
                m = fftn(m);
                [fy,fx] = ndgrid(...
                    (-sz(1)/2:sz(1)/2-1)/degxy(2), ...
                    (-sz(2)/2:sz(2)/2-1)/degxy(1));   % in
                fxy = ifftshift(sqrt(fy.^2 + fx.^2));  % radial frequency
                sigmoid = 1./(1+exp(-200*(fxy-cond.spatial_freq_half/10)));  % remove zero frequency
                cutoff = fxy<cond.spatial_freq_stop;
                xymask = cutoff;
                xymask = xymask.*sigmoid./(1+fxy/cond.spatial_freq_half);  % 1/f filter
                m = bsxfun(@times, m, xymask);
                
                % normalize to [-1 1]
                result = real(ifftn(m));                % back to spacetime
                scale = quantile(abs(result(:)), 1-1e-5);
                m = m/scale;
                result = result/scale;
                sigma = std(result(:));
                
                % modulate orientation
                directions = (r.randperm(cond.n_dirs)-1)/cond.n_dirs*2*pi;
                onsets = nan(size(directions));
                offsets =  nan(size(directions));
                frametimes = (0:nFrames-1)'/fps;
                theta = ifftshift(atan2(fx,fy));
                speed = zeros(size(frametimes));
                for i=1:cond.n_dirs
                    q = theta + directions(i);
                    space_bias = hamm(q, cond.ori_bands*2*pi/cond.n_dirs);
                    biased = real(ifftn(bsxfun(@times, space_bias, m)));
                    biased = result + cond.ori_modulation*(biased*sigma/std(biased(:)) - result);
                    biased = sigma/std(biased(:))*biased;
                    mix = abs(frametimes - (i-0.5)*(period)) < cond.ori_on_secs/2;
                    onsets(i) = (i-0.5)*period - cond.ori_on_secs/2;
                    offsets(i) = (i-0.5)*period + cond.ori_on_secs/2;
                    speed = speed - mix*exp(-1i*directions(i));
                    result = result + bsxfun(@times, biased-result, permute(mix,[3 2 1]));
                end
                m = result;
                clear result
                
                % apply motion
                offset = cumsum(speed*cond.speed/fps);
                for i=1:sz(3)
                    shift = ifftshift(exp(...
                        -2i*pi*fx*imag(offset(i)) ...
                        -2i*pi*fy*real(offset(i))));
                    f = fft2(m(:,:,i)).*shift;
                    m(:,:,i) = real(ifft2(f));
                end
                
                % save results
                m = max(-1, min(1, m)).*(abs(m)>0.001);
                m = uint8((m+1)/2*254);
                
                tuple = key;
                stim.frametimes = frametimes;
                stim.direction = directions;
                stim.onsets = onsets;
                stim.offsets = offsets;
                
                tuple.params = [params {stim}];
                tuple.cached_movie = m;
                
                self.insert(tuple)
            end
        end
    end
    
end


function y = hamm(q, width)
q = (mod(q + pi/2,pi)-pi/2)/width;
y = (0.54 + 0.46*cos(q*pi)).*(abs(q)<1);
end