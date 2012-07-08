package away3d.animators
{
	import away3d.animators.nodes.SkeletonNaryLERPNode;
	import away3d.animators.nodes.SkeletonNodeBase;
	import away3d.animators.nodes.SkeletonClipNode;
	import away3d.errors.AbstractMethodError;
	import away3d.entities.Mesh;
	import away3d.materials.passes.MaterialPassBase;
	import away3d.core.base.SubMesh;
	import flash.geom.Vector3D;
	import away3d.core.math.Quaternion;
	import away3d.animators.skeleton.SkeletonJoint;
	import away3d.animators.skeleton.JointPose;
	import flash.display3D.Context3DProgramType;
	import away3d.core.base.SkinnedSubGeometry;
	import flash.utils.Dictionary;
	import away3d.animators.skeleton.SkeletonPose;
	import away3d.animators.skeleton.Skeleton;
	import away3d.core.base.IRenderable;
	import away3d.core.managers.Stage3DProxy;
	import away3d.animators.data.SkeletonAnimationSequence;
	import away3d.animators.nodes.SkeletonTimelineClipNode;
	import away3d.animators.nodes.SkeletonTreeNode;
	import away3d.arcane;

	use namespace arcane;

	/**
	 * AnimationSequenceController provides a controller for single clip-based animation sequences (fe: md2, md5anim).
	 */
	public class SkeletonAnimator extends AnimatorBase implements IAnimator
	{
		private var _activeNode : SkeletonNodeBase;
		private var _activeState:SkeletonAnimationState;
		private var _absoluteTime : Number;
		
		private var _globalMatrices : Vector.<Number>;
        private var _globalPose : SkeletonPose = new SkeletonPose();
		private var _globalPropertiesDirty : Boolean;
		private var _numJoints : uint;
		private var _bufferFormat : String;
        private var _blendTree : SkeletonTreeNode;
		private var _animationStates : Dictionary = new Dictionary();
		private var _condensedMatrices : Vector.<Number>;
		
		private var _skeletonAnimationSet:SkeletonAnimationSet;
        private var _skeleton : Skeleton;
		private var _forceCPU : Boolean;
		private var _useCondensedIndices : Boolean;
		private var _jointsPerVertex : uint;
		
		public var updateRootPosition:Boolean = true;
		
		public function get globalMatrices():Vector.<Number>
		{
			if (_globalPropertiesDirty)
				updateGlobalProperties();
			
			return _globalMatrices;
		}
		
		public function get globalPose():SkeletonPose
		{
			if (_globalPropertiesDirty)
				updateGlobalProperties();
			
			return _globalPose;
		}
		
		/**
		 * Creates a new AnimationSequenceController object.
		 */
		public function SkeletonAnimator(skeletonAnimationSet:SkeletonAnimationSet, skeleton : Skeleton, forceCPU : Boolean = false)
		{
			super(skeletonAnimationSet);
			
			_skeletonAnimationSet = skeletonAnimationSet;
			_skeleton = skeleton;
			_forceCPU = forceCPU;
			_jointsPerVertex = _skeletonAnimationSet.jointsPerVertex;
			
			_numJoints = _skeleton.numJoints;
			_globalMatrices = new Vector.<Number>(_numJoints*12, true);
			_bufferFormat = "float" + _jointsPerVertex;

			var j : int;
			for (var i : uint = 0; i < _numJoints; ++i) {
				_globalMatrices[j++] = 1; _globalMatrices[j++] = 0; _globalMatrices[j++] = 0; _globalMatrices[j++] = 0;
				_globalMatrices[j++] = 0; _globalMatrices[j++] = 1; _globalMatrices[j++] = 0; _globalMatrices[j++] = 0;
				_globalMatrices[j++] = 0; _globalMatrices[j++] = 0; _globalMatrices[j++] = 1; _globalMatrices[j++] = 0;
			}
			
			_blendTree = new SkeletonNaryLERPNode();
		}
		
		/**
		 * Plays a state with a given name. If the sequence is not found, it may not be loaded yet, and it will retry every frame.
		 * @param sequenceName The name of the clip to be played.
		 */
		public function play(stateName : String, crossFadeTime : Number = 0) : void
		{
			_activeState = _skeletonAnimationSet.getState(stateName) as SkeletonAnimationState;
			
			if (!_activeState)
				throw new Error("Animation state " + stateName + " not found!");
			
			_activeNode = _activeState.rootNode as SkeletonNodeBase;
			
			//_crossFadeTime = crossFadeTime;
			/*
			var clip : SkeletonTimelineClipNode = _clips[sequenceName];

			if (!clip)
				throw new Error("Clip not found!");
			if (clip.duration == 0)
				throw new Error("Invalid clip: duration is 0!");

			if (crossFadeTime == 0)
				setActiveClipDirect(clip);
			else
				setActiveClipWithFadeOut(clip);
			*/
			_absoluteTime = 0;
			
			_activeNode.update(_absoluteTime);
			
			start();
		}
		
		override protected function updateAnimation(realDT : Number, scaledDT : Number) : void
		{
			_absoluteTime += scaledDT;
			
			//invalidate pose matrices
			_globalPropertiesDirty = true;
			
			for(var key : Object in _animationStates)
			    SubGeomAnimationState(_animationStates[key]).dirty = true;
			
			_activeNode.update(_absoluteTime);
			
			if (updateRootPosition)
				applyRootDelta();
		}
		
		/**
		 * @inheritDoc
		 */
        public function setRenderState(stage3DProxy : Stage3DProxy, renderable : IRenderable, vertexConstantOffset : int, vertexStreamOffset : int) : void
		{
			// do on request of globalProperties
			if (_globalPropertiesDirty)
				updateGlobalProperties();

			var skinnedGeom : SkinnedSubGeometry = SkinnedSubGeometry(SubMesh(renderable).subGeometry);

			// using condensed data
			var numCondensedJoints : uint = skinnedGeom.numCondensedJoints;
			if (_useCondensedIndices) {
				if (skinnedGeom.numCondensedJoints == 0)
					skinnedGeom.condenseIndexData();
				updateCondensedMatrices(skinnedGeom.condensedIndexLookUp, numCondensedJoints);
				stage3DProxy._context3D.setProgramConstantsFromVector(Context3DProgramType.VERTEX, vertexConstantOffset, _condensedMatrices, numCondensedJoints*3);
			}
			else {
				if (_skeletonAnimationSet.usesCPU) {
					var subGeomAnimState : SubGeomAnimationState = _animationStates[skinnedGeom] ||= new SubGeomAnimationState(skinnedGeom);

					if (subGeomAnimState.dirty) {
						morphGeometry(subGeomAnimState, skinnedGeom);
						subGeomAnimState.dirty = false;
					}
					skinnedGeom.animatedVertexData = subGeomAnimState.animatedVertexData;
					skinnedGeom.animatedNormalData = subGeomAnimState.animatedNormalData;
					skinnedGeom.animatedTangentData = subGeomAnimState.animatedTangentData;
					return;
				}
				stage3DProxy._context3D.setProgramConstantsFromVector(Context3DProgramType.VERTEX, vertexConstantOffset, _globalMatrices, _numJoints*3);
			}

			stage3DProxy.setSimpleVertexBuffer(vertexStreamOffset, skinnedGeom.getJointIndexBuffer(stage3DProxy), _bufferFormat, 0);
			stage3DProxy.setSimpleVertexBuffer(vertexStreamOffset+1, skinnedGeom.getJointWeightsBuffer(stage3DProxy), _bufferFormat, 0);
		}
		
		private function updateCondensedMatrices(condensedIndexLookUp : Vector.<uint>, numJoints : uint) : void
		{
			var i : uint = 0, j : uint = 0;
			var len : uint;
			var srcIndex : uint;

			_condensedMatrices = new Vector.<Number>();

			do {
				srcIndex = condensedIndexLookUp[i*3]*4;
				len = srcIndex+12;
				// copy into condensed
				while (srcIndex < len)
					_condensedMatrices[j++] = _globalMatrices[srcIndex++];
			} while (++i < numJoints);
		}
		
		private function updateGlobalProperties() : void
		{
			_globalPropertiesDirty = false;
			
			//get global pose
			localToGlobalPose(_activeNode.getSkeletonPose(_skeleton), _globalPose, _skeleton);
			
			// convert pose to matrix
		    var mtxOffset : uint;
			var globalPoses : Vector.<JointPose> = _globalPose.jointPoses;
			var raw : Vector.<Number>;
			var ox : Number, oy : Number, oz : Number, ow : Number;
			var xy2 : Number, xz2 : Number, xw2 : Number;
			var yz2 : Number, yw2 : Number, zw2 : Number;
			var xx : Number, yy : Number, zz : Number, ww : Number;
			var n11 : Number, n12 : Number, n13 : Number, n14 : Number;
			var n21 : Number, n22 : Number, n23 : Number, n24 : Number;
			var n31 : Number, n32 : Number, n33 : Number, n34 : Number;
			var m11 : Number, m12 : Number, m13 : Number, m14 : Number;
			var m21 : Number, m22 : Number, m23 : Number, m24 : Number;
			var m31 : Number, m32 : Number, m33 : Number, m34 : Number;
			var joints : Vector.<SkeletonJoint> = _skeleton.joints;
			var pose : JointPose;
			var quat : Quaternion;
			var vec : Vector3D;

			for (var i : uint = 0; i < _numJoints; ++i) {
				pose = globalPoses[i];
				quat = pose.orientation;
				vec = pose.translation;
				ox = quat.x;	oy = quat.y;	oz = quat.z;	ow = quat.w;
				xy2 = 2.0 * ox * oy; 	xz2 = 2.0 * ox * oz; 	xw2 = 2.0 * ox * ow;
				yz2 = 2.0 * oy * oz; 	yw2 = 2.0 * oy * ow; 	zw2 = 2.0 * oz * ow;
				xx = ox * ox;			yy = oy * oy;			zz = oz * oz; 			ww = ow * ow;

				n11 = xx - yy - zz + ww;	n12 = xy2 - zw2;			n13 = xz2 + yw2;			n14 = vec.x;
				n21 = xy2 + zw2;			n22 = -xx + yy - zz + ww;	n23 = yz2 - xw2;			n24 = vec.y;
				n31 = xz2 - yw2;			n32 = yz2 + xw2;			n33 = -xx - yy + zz + ww;	n34 = vec.z;

				// prepend inverse bind pose
				raw = joints[i].inverseBindPose;
				m11 = raw[0];	m12 = raw[4];	m13 = raw[8];	m14 = raw[12];
				m21 = raw[1];	m22 = raw[5];   m23 = raw[9];	m24 = raw[13];
				m31 = raw[2];   m32 = raw[6];   m33 = raw[10];  m34 = raw[14];

				_globalMatrices[mtxOffset++] = n11 * m11 + n12 * m21 + n13 * m31;
				_globalMatrices[mtxOffset++] = n11 * m12 + n12 * m22 + n13 * m32;
				_globalMatrices[mtxOffset++] = n11 * m13 + n12 * m23 + n13 * m33;
				_globalMatrices[mtxOffset++] = n11 * m14 + n12 * m24 + n13 * m34 + n14;
				_globalMatrices[mtxOffset++] = n21 * m11 + n22 * m21 + n23 * m31;
				_globalMatrices[mtxOffset++] = n21 * m12 + n22 * m22 + n23 * m32;
				_globalMatrices[mtxOffset++] = n21 * m13 + n22 * m23 + n23 * m33;
				_globalMatrices[mtxOffset++] = n21 * m14 + n22 * m24 + n23 * m34 + n24;
				_globalMatrices[mtxOffset++] = n31 * m11 + n32 * m21 + n33 * m31;
				_globalMatrices[mtxOffset++] = n31 * m12 + n32 * m22 + n33 * m32;
				_globalMatrices[mtxOffset++] = n31 * m13 + n32 * m23 + n33 * m33;
				_globalMatrices[mtxOffset++] = n31 * m14 + n32 * m24 + n33 * m34 + n34;
			}
		}
		
		/**
		 * If the animation can't be performed on GPU, transform vertices manually
		 * @param subGeom The subgeometry containing the weights and joint index data per vertex.
		 * @param pass The material pass for which we need to transform the vertices
		 *
		 * todo: we may be able to transform tangents more easily, similar to how it happens on gpu
		 */
		private function morphGeometry(state : SubGeomAnimationState, subGeom : SkinnedSubGeometry) : void
		{
			var verts : Vector.<Number> = subGeom.vertexData;
			var normals : Vector.<Number> = subGeom.vertexNormalData;
			var tangents : Vector.<Number> = subGeom.vertexTangentData;
			var targetVerts : Vector.<Number> = state.animatedVertexData;
			var targetNormals : Vector.<Number> = state.animatedNormalData;
			var targetTangents : Vector.<Number> = state.animatedTangentData;
			var jointIndices : Vector.<Number> = subGeom.jointIndexData;
			var jointWeights : Vector.<Number> = subGeom.jointWeightsData;
			var i1 : uint, i2 : uint = 1, i3 : uint = 2;
			var j : uint, k : uint;
			var vx : Number, vy : Number, vz : Number;
			var nx : Number, ny : Number, nz : Number;
			var tx : Number, ty : Number, tz : Number;
			var len : int = verts.length;
			var weight : Number;
			var mtxOffset : uint;
			var vertX : Number, vertY : Number, vertZ : Number;
			var normX : Number, normY : Number, normZ : Number;
			var tangX : Number, tangY : Number, tangZ : Number;
			var m11 : Number, m12 : Number, m13 : Number;
			var m21 : Number, m22 : Number, m23 : Number;
			var m31 : Number, m32 : Number, m33 : Number;

			while (i1 < len) {
				vertX = verts[i1]; vertY = verts[i2]; vertZ = verts[i3];
				vx = 0; vy = 0; vz = 0;
				normX = normals[i1]; normY = normals[i2]; normZ = normals[i3];
				nx = 0; ny = 0; nz = 0;
				tangX = tangents[i1]; tangY = tangents[i2]; tangZ = tangents[i3];
				tx = 0; ty = 0; tz = 0;

				// todo: can we use actual matrices when using cpu + using matrix.transformVectors, then adding them in loop?

				k = 0;
				while (k < _jointsPerVertex) {
					weight = jointWeights[j];
					if (weight == 0) {
						j += _jointsPerVertex - k;
						k = _jointsPerVertex;
					}
					else {
						// implicit /3*12 (/3 because indices are multiplied by 3 for gpu matrix access, *12 because it's the matrix size)
						mtxOffset = jointIndices[uint(j++)]*4;
						m11 = _globalMatrices[mtxOffset]; m12 = _globalMatrices[mtxOffset+1]; m13 = _globalMatrices[mtxOffset+2];
						m21 = _globalMatrices[mtxOffset+4]; m22 = _globalMatrices[mtxOffset+5]; m23 = _globalMatrices[mtxOffset+6];
						m31 = _globalMatrices[mtxOffset+8]; m32 = _globalMatrices[mtxOffset+9]; m33 = _globalMatrices[mtxOffset+10];
						vx += weight*(m11*vertX + m12*vertY + m13*vertZ + _globalMatrices[mtxOffset+3]);
						vy += weight*(m21*vertX + m22*vertY + m23*vertZ + _globalMatrices[mtxOffset+7]);
						vz += weight*(m31*vertX + m32*vertY + m33*vertZ + _globalMatrices[mtxOffset+11]);

						nx += weight*(m11*normX + m12*normY + m13*normZ);
						ny += weight*(m21*normX + m22*normY + m23*normZ);
						nz += weight*(m31*normX + m32*normY + m33*normZ);
						tx += weight*(m11*tangX + m12*tangY + m13*tangZ);
						ty += weight*(m21*tangX + m22*tangY + m23*tangZ);
						tz += weight*(m31*tangX + m32*tangY + m33*tangZ);
						k++;
					}
				}

				targetVerts[i1] = vx; targetVerts[i2] = vy; targetVerts[i3] = vz;
				targetNormals[i1] = nx; targetNormals[i2] = ny; targetNormals[i3] = nz;
				targetTangents[i1] = tx; targetTangents[i2] = ty; targetTangents[i3] = tz;

				i1 += 3; i2 += 3; i3 += 3;
			}
		}
		
		
		/**
		 * Converts a local hierarchical skeleton pose to a global pose
		 * @param targetPose The SkeletonPose object that will contain the global pose.
		 * @param skeleton The skeleton containing the joints, and as such, the hierarchical data to transform to global poses.
		 */
		public function localToGlobalPose(sourcePose : SkeletonPose, targetPose : SkeletonPose, skeleton : Skeleton) : void
		{
			var globalPoses : Vector.<JointPose> = targetPose.jointPoses;
			var globalJointPose : JointPose;
			var joints : Vector.<SkeletonJoint> = skeleton.joints;
			var len : uint = sourcePose.numJointPoses;
			var jointPoses : Vector.<JointPose> = sourcePose.jointPoses;
			var parentIndex : int;
			var joint : SkeletonJoint;
			var parentPose : JointPose;
			var pose : JointPose;
			var or : Quaternion;
			var tr : Vector3D;
			var t : Vector3D;
			var q : Quaternion;

			var x1 : Number, y1 : Number, z1 : Number, w1 : Number;
			var x2 : Number, y2 : Number, z2 : Number, w2 : Number;
			var x3 : Number, y3 : Number, z3 : Number;

			// :s
			if (globalPoses.length != len) globalPoses.length = len;

			for (var i : uint = 0; i < len; ++i) {
				globalJointPose = globalPoses[i] ||= new JointPose();
				joint = joints[i];
				parentIndex = joint.parentIndex;
				pose = jointPoses[i];

				q = globalJointPose.orientation;
				t = globalJointPose.translation;

				if (parentIndex < 0) {
					tr = pose.translation;
					or = pose.orientation;
					q.x = or.x;
					q.y = or.y;
					q.z = or.z;
					q.w = or.w;
					t.x = tr.x;
					t.y = tr.y;
					t.z = tr.z;
				}
				else {
					// append parent pose
					parentPose = globalPoses[parentIndex];

					// rotate point
					or = parentPose.orientation;
					tr = pose.translation;
					x2 = or.x;
					y2 = or.y;
					z2 = or.z;
					w2 = or.w;
					x3 = tr.x;
					y3 = tr.y;
					z3 = tr.z;

					w1 = -x2 * x3 - y2 * y3 - z2 * z3;
					x1 = w2 * x3 + y2 * z3 - z2 * y3;
					y1 = w2 * y3 - x2 * z3 + z2 * x3;
					z1 = w2 * z3 + x2 * y3 - y2 * x3;

					// append parent translation
					tr = parentPose.translation;
					t.x = -w1 * x2 + x1 * w2 - y1 * z2 + z1 * y2 + tr.x;
					t.y = -w1 * y2 + x1 * z2 + y1 * w2 - z1 * x2 + tr.y;
					t.z = -w1 * z2 - x1 * y2 + y1 * x2 + z1 * w2 + tr.z;

					// append parent orientation
					x1 = or.x;
					y1 = or.y;
					z1 = or.z;
					w1 = or.w;
					or = pose.orientation;
					x2 = or.x;
					y2 = or.y;
					z2 = or.z;
					w2 = or.w;

					q.w = w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2;
					q.x = w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2;
					q.y = w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2;
					q.z = w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2;
				}
			}
		}
		
		public function applyRootDelta() : void
		{
			var delta : Vector3D = _activeNode.rootDelta;
			var dist : Number = delta.length;
			var len : uint;
			if (dist > 0) {
				len = _owners.length;
				for (var i : uint = 0; i < len; ++i)
					_owners[i].translateLocal(delta, dist);
			}
		}
		
        /**
         * Verifies if the animation will be used on cpu. Needs to be true for all passes for a material to be able to use it on gpu.
		 * Needs to be called if gpu code is potentially required.
         */
        public function testGPUCompatibility(pass : MaterialPassBase) : void
        {
			if (!_useCondensedIndices && (_forceCPU || _jointsPerVertex > 4 || pass.numUsedVertexConstants + _numJoints * 3 > 128)) {
				_skeletonAnimationSet._usesCPU = true;
			}
        }
	}
}

import away3d.core.base.SubGeometry;

class SubGeomAnimationState
{
	public var animatedVertexData : Vector.<Number>;
	public var animatedNormalData : Vector.<Number>;
	public var animatedTangentData : Vector.<Number>;
	public var dirty : Boolean = true;

	public function SubGeomAnimationState(subGeom : SubGeometry)
	{
		animatedVertexData = subGeom.vertexData.concat();
		animatedNormalData = subGeom.vertexNormalData.concat();
		animatedTangentData = subGeom.vertexTangentData.concat();
	}
}