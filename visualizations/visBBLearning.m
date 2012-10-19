function [] = visBBLearning(RBM,iE,jB);
%-----------------------------------------
%  [] = visRBMLearning(RBM,jB,iE,rotFlag);
%-----------------------------------------
% DES
set(gcf,'name','Learning BB RBM');
if notDefined('iE')
	iE = numel(RBM.log.err);
end

nVis = floor(sqrt(size(RBM.W,1))).^2;

subplot(331);
visWeights(RBM.X(RBM.batchIdx{jB},:)',1);
title('Batch Data');

subplot(332);
visWeights(RBM.pVis(:,1:nVis)',1);
title('Reconstructions');

subplot(333);
visWeights(RBM.dW(1:nVis,:),1,[]);
title ('Weight Gradients');


subplot(334);
visWeights(RBM.b(1:nVis)',1);
title('Visible Bias');

subplot(335);
hist(RBM.W(:),20);
title('Connection Weights');

subplot(336);
visWeights(RBM.W(1:nVis,:),1,[]);
title('Connection Weights');

subplot(337);
plot(RBM.log.err(1:iE));
title('Reconstruction errors');

subplot(338);
visWeights(RBM.aHid',1);
title('Hidden Activations');

subplot(339);
plot(RBM.log.eta(1:iE));
title('Learning Rate');

drawnow
