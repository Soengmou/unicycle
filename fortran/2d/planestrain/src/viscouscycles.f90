!-----------------------------------------------------------------------
!> program ViscousCycles simulates evolution of fault slip in a 
!! viscoelastic medium in condition of plane strain under the 
!! radiation damping approximation.
!!
!! \mainpage
!! 
!! The Green's function for traction and stress interaction amongst the
!! dislocations and strain volumes has the following layout
!!
!!       / KK  KL \
!!   G = |        |
!!       \ LK  LL /
!!
!! where
!!
!!   KK is the matrix for traction on faults due to fault slip
!!   KL is the matrix for traction on faults due to volume strain
!!
!!   LK is the matrix for stress in volumes due to fault slip
!!   LL is the matrix for stress in volumes due to strain in volumes
!!
!! The volumes have three strain directions: e22, e23, and e33. The
!! interaction matrices become
!!
!!        / LL2222  LL2223  LL2233 \
!!        |                        |
!!   LL = | LL2322  LL2323  LL2333 |
!!        |                        |
!!        \ LL3322  LL3323  LL3333 /
!!
!!   KL = | KLd22   KLd23   KLd33  |
!!
!!        / LK22s \
!!        |       |
!!   LK = | LK23s |
!!        |       |
!!        \ LK33d /
!!
!! The time evolution is evaluated numerically using the 4th/5th order
!! Runge-Kutta method with adaptive time steps. The state vector is 
!! as follows:
!!
!!    / P1 1       \   +-----------------------+
!!    | .          |   |                       |
!!    | P1 dPatch  |   |                       |
!!    | .          |   |    nPatch * dPatch    |
!!    | .          |   |                       |
!!    | Pn 1       |   |                       |
!!    | .          |   |                       |
!!    | Pn dPatch  |   +-----------------------+
!!    |            |                          
!!    | V1 1       |   +-----------------------+
!!    | .          |   |                       |
!!    | V1 dVolume |   |                       |
!!    | .          |   |   nVolume * dVolume   |
!!    | .          |   |                       |
!!    | Vn 1       |   |                       |
!!    | .          |   |                       |
!!    \ Vn dVolume /   +-----------------------+
!!
!! where nPatch and nVolume are the number of patches and the number 
!! of strain volumes, respectively, and dPatch and dVolume are the 
!! degrees of freedom for patches and volumes. 
!!
!! For every patch, we have the following items in the state vector
!!
!!   /   td    \  1
!!   |   tn    |  .
!!   |   sd    |  .
!!   !  theta* |  .
!!   \   v*    /  dPatch
!!
!! where td and tn are the local traction in the dip and normal direction, 
!! sd is the slip in the dip direction, v* is the logarithm of the norm of the 
!! velocity vector (v*=log10(V)), and theta* is the logarithm of the state 
!! variable (theta*=log10(theta)) in the rate and state friction framework.
!!
!! For every strain volume, we have the following items in the state vector
!!
!!   /  s22   \  1
!!   |  s23   |  . 
!!   |  s33   |  . 
!!   |  e22   |  .
!!   |  e23   |  .
!!   \  e33   /  dVolume
!!
!! where s22, s32 and s33 are the three independent components of the local stress 
!! tensor in plane strain, and e22, e23 and e33 are the three independent components
!! of the cumulative anelastic strain tensor.
!!
!! References:<br>
!!
!!   Barbot S., J. D.-P. Moore, and V. Lambert, "Displacement and Stress
!!   Associated with Distributed Anelastic Deformation in a Half-Space",
!!   Bull. Seism. Soc. Am., 10.1785/0120160237, 2017.
!!
!! \author Sylvain Barbot (2017).
!----------------------------------------------------------------------
PROGRAM viscouscycles

#include "macros.f90"

#ifdef NETCDF
  USE exportnetcdf
#endif
  USE planestrain
  USE greens
  USE ode45
  USE types 

  IMPLICIT NONE

  INCLUDE 'mpif.h'

  TYPE(SIMULATION_STRUCT) :: iparam

  REAL*8, PARAMETER :: pi=3.141592653589793d0
  REAL*8, PARAMETER :: DEG2RAD = 0.01745329251994329547437168059786927_8

  ! MPI rank and size
  INTEGER :: rank,csize

  ! error flag
  INTEGER :: ierr

#ifdef NETCDF
  ! netcdf file and variable
  INTEGER :: ncid,y_varid,z_varid,ncCount
#endif

  CHARACTER(256) :: filename

  ! maximum strain rate, maximum velocity
  REAL*8 :: eMax, vMax

  ! scaling factor
  REAL*8, PARAMETER :: lg10=LOG(1.d1)

  ! state vector
  REAL*8, DIMENSION(:), ALLOCATABLE :: y
  ! rate of change of state vector
  REAL*8, DIMENSION(:), ALLOCATABLE :: dydt,yscal
  ! temporary variables
  REAL*8, DIMENSION(:), ALLOCATABLE :: ytmp,ytmp1,ytmp2,ytmp3

  ! slip velocity vector and strain rate tensor array (temporary space)
  REAL*8, DIMENSION(:), ALLOCATABLE :: v

  ! slip velocity vector and strain rate tensor array (temporary space)
  REAL*8, DIMENSION(:), ALLOCATABLE :: vAll

  ! traction vector and stress tensor array (temporary space)
  REAL*8, DIMENSION(:), ALLOCATABLE :: t

  ! displacement and kinematics vector
  REAL*8, DIMENSION(:), ALLOCATABLE :: d,u,dAll,dfAll,dlAll

  ! Green's function
  REAL*8, DIMENSION(:,:), ALLOCATABLE :: G,O,Of,Ol

  ! time
  REAL*8 :: time,t0
  ! time step
  REAL*8 :: dt_try,dt_next,dt_done
  ! time steps
  INTEGER :: i,j

  ! maximum number of time steps (default)
  INTEGER :: maximumIterations=1000000

  ! layout for parallelism
  TYPE(LAYOUT_STRUCT) :: layout

  ! model parameters
  TYPE(SIMULATION_STRUCT) :: in

  ! initialization
  CALL MPI_INIT(ierr)
  CALL MPI_COMM_RANK(MPI_COMM_WORLD,rank,ierr)
  CALL MPI_COMM_SIZE(MPI_COMM_WORLD,csize,ierr)

  ! start time
  time=0.0d0

  ! initial tentative time step
  dt_next=1.0d-3

  ! retrieve input parameters from command line
  CALL init(in)
  CALL FLUSH(STDOUT)

  IF (in%isdryrun .AND. 0 .EQ. rank) THEN
     PRINT '("dry run: abort calculation")'
  END IF
  IF (in%isdryrun .OR. in%isversion .OR. in%ishelp) THEN
     CALL MPI_FINALIZE(ierr)
     STOP
  END IF

  ! calculate basis vectors
  CALL initGeometry(in)

  ! describe data layout for parallelism
  CALL initParallelism(in,layout)

  ! calculate the stress interaction matrix
  IF (0 .EQ. rank) THEN
     PRINT '("# computing Green''s functions.")'
  END IF

  CALL buildG(in,layout,G)
  CALL buildO(in,layout,O,Of,Ol)

#ifdef NETCDF
  IF (in%isexportgreens) THEN
     CALL exportGreensNetcdf(G)
  END IF
#endif

  IF (0 .EQ. rank) THEN
     PRINT 2000
  END IF

  ! velocity vector and strain rate tensor array (t=G*vAll)
  ALLOCATE(u(layout%listVelocityN(1+rank)), &
           v(layout%listVelocityN(1+rank)), &
           vAll(SUM(layout%listVelocityN)),STAT=ierr)
  IF (ierr>0) STOP "could not allocate the velocity and strain rate vector"

  ! traction vector and stress tensor array (t=G*v)
  ALLOCATE(t(layout%listForceN(1+rank)),STAT=ierr)
  IF (ierr>0) STOP "could not allocate the traction and stress vector"

  ! displacement vector (d=O*v)
  ALLOCATE(d   (in%nObservationPoint*DISPLACEMENT_VECTOR_DGF), &
           dAll (in%nObservationPoint*DISPLACEMENT_VECTOR_DGF), &
           dfAll(in%nObservationPoint*DISPLACEMENT_VECTOR_DGF), &
           dlAll(in%nObservationPoint*DISPLACEMENT_VECTOR_DGF),STAT=ierr)
  IF (ierr>0) STOP "could not allocate the displacement vector"

  ALLOCATE(y(layout%listStateN(1+rank)),STAT=ierr)
  IF (ierr>0) STOP "could not allocate the state vector"

  ALLOCATE(dydt(layout%listStateN(1+rank)), &
           yscal(layout%listStateN(1+rank)),STAT=ierr)
  IF (ierr>0) STOP "could not allocate the state vectors"

  ALLOCATE(ytmp (layout%listStateN(1+rank)), &
           ytmp1(layout%listStateN(1+rank)), &
           ytmp2(layout%listStateN(1+rank)), &
           ytmp3(layout%listStateN(1+rank)),STAT=ierr)
  IF (ierr>0) STOP "could not allocate the RKQS work space"

  ! allocate buffer from ode45 module
  ALLOCATE(AK2(layout%listStateN(1+rank)), &
           AK3(layout%listStateN(1+rank)), &
           AK4(layout%listStateN(1+rank)), &
           AK5(layout%listStateN(1+rank)), &
           AK6(layout%listStateN(1+rank)), &
           yrkck(layout%listStateN(1+rank)), STAT=ierr)
  IF (ierr>0) STOP "could not allocate the AK1-6 work space"

  IF (0 .EQ. rank) THEN
     OPEN (UNIT=FPTIME,FILE=in%timeFilename,IOSTAT=ierr,FORM="FORMATTED")
     IF (ierr>0) THEN
        WRITE_DEBUG_INFO(102)
        WRITE (STDERR,'("error: unable to access ",a)') TRIM(in%timefilename)
        STOP 1
     END IF
  END IF

  ! initialize the y vector
  IF (0 .EQ. rank) THEN
     PRINT '("# initialize state vector.")'
  END IF

  CALL initStateVector(layout%listStateN(1+rank),y,in)
  IF (ALLOCATED(in%strainVolume%s0)) DEALLOCATE(in%strainVolume%s0)

  IF (0 .EQ. rank) THEN
     PRINT 2000
  END IF

#ifdef NETCDF
  ! initialize netcdf output
  IF (in%isexportnetcdf) THEN
     CALL initnc()
  END IF
#endif

  ! initialize output
  IF (0 .EQ. rank) THEN
     WRITE(STDOUT,'("#       n               time                 dt       vMax       eMax")')
     WRITE(STDOUT,'(I9.9,ES19.12E2,ES19.12E2)') 0,time,dt_next
     WRITE(FPTIME,'("#               time                 dt")')
     WRITE(FPTIME,'(ES19.12E2,ES19.12E2)') ZERO,dt_next
  END IF

  ! initialize observation states
  DO j=1,in%nObservationState
     IF ((in%observationState(j,1) .GE. layout%listOffset(rank+1)) .AND. &
         (in%observationState(j,1) .LT. layout%listOffset(rank+1)+layout%listElements(rank+1))) THEN

        SELECT CASE(layout%elementType(in%observationState(j,1)-layout%listOffset(rank+1)+1))
        CASE (FLAG_PATCH)
           WRITE (filename,'(a,"/patch-",I8.8,".dat")') TRIM(in%wdir),in%observationState(j,1)
        CASE (FLAG_VOLUME)
           WRITE (filename,'(a,"/volume-",I8.8,".dat")') TRIM(in%wdir),in%observationState(j,1)-in%nPatch
        CASE DEFAULT
           WRITE (STDERR,'("wrong case: this is a bug.")')
           WRITE_DEBUG_INFO(-1)
           STOP -1
        END SELECT

        in%observationState(j,2)=100+j
        OPEN (UNIT=in%observationState(j,2), &
              FILE=filename,IOSTAT=ierr,FORM="FORMATTED")
        IF (ierr>0) THEN
           WRITE_DEBUG_INFO(102)
           WRITE (STDERR,'("error: unable to access ",a)') TRIM(filename)
           STOP 1
        END IF
     END IF
  END DO

  ! initialize observation points
  IF (0 .EQ. rank) THEN
     DO j=1,in%nObservationPoint
        in%observationPoint(j)%file=1000+j
        WRITE (filename,'(a,"/opts-",a,".dat")') TRIM(in%wdir),TRIM(in%observationPoint(j)%name)
        OPEN (UNIT=in%observationPoint(j)%file, &
              FILE=filename,IOSTAT=ierr,FORM="FORMATTED")
        IF (ierr>0) THEN
           WRITE_DEBUG_INFO(102)
           WRITE (STDERR,'("error: unable to access ",a)') TRIM(filename)
           STOP 1
        END IF
     END DO
  END IF

  ! main loop
  DO i=1,maximumIterations

     CALL odefun(layout%listStateN(1+rank),time,y,dydt)

     CALL export()
     CALL exportPoints()

#ifdef NETCDF
     IF (0 .EQ. rank) THEN
        IF (in%isexportnetcdf) THEN
           IF (0 .EQ. MOD(i,20)) THEN
              CALL exportnc(in%nPatch)
           END IF
        END IF
     END IF
#endif

     dt_try=dt_next
     yscal(:)=abs(y(:))+abs(dt_try*dydt(:))+TINY

     t0=ZERO
     CALL RKQSm(layout%listStateN(1+rank),t0,y,dydt, &
               yscal,ytmp1,ytmp2,ytmp3,dt_try,dt_done,dt_next,odefun)

     time=time+dt_done

     ! end calculation
     IF (in%interval .LE. time) THEN
        EXIT
     END IF
   
  END DO

  IF (0 .EQ. rank) THEN
     PRINT '(I9.9," time steps.")', i
  END IF

  IF (0 .EQ. rank) THEN
     CLOSE(FPTIME)
  END IF

  ! close observation patch files
  DO j=1,in%nObservationState
     IF ((in%observationState(j,1) .GE. layout%listOffset(rank+1)) .AND. &
         (in%observationState(j,1) .LT. layout%listOffset(rank+1)+layout%listElements(rank+1))) THEN
        CLOSE(in%observationState(j,2))
     END IF
  END DO

  ! close the observation points
  IF (0 .EQ. rank) THEN
     DO j=1,in%nObservationPoint
        CLOSE(in%observationPoint(j)%file)
     END DO
  END IF

#ifdef NETCDF
  ! close the netcdf file
  IF (0 .EQ. rank) THEN
     IF (in%isexportnetcdf) THEN
        CALL closeNetcdfUnlimited(ncid,y_varid,z_varid,ncCount)
     END IF
  END IF
#endif

  DEALLOCATE(y,dydt,yscal)
  DEALLOCATE(ytmp,ytmp1,ytmp2,ytmp3,yrkck)
  DEALLOCATE(AK2,AK3,AK4,AK5,AK6)
  DEALLOCATE(G,v,vAll,t)
  DEALLOCATE(layout%listForceN)
  DEALLOCATE(layout%listVelocityN,layout%listVelocityOffset)
  DEALLOCATE(layout%listStateN,layout%listStateOffset)
  DEALLOCATE(layout%elementStateIndex)
  DEALLOCATE(layout%listElements,layout%listOffset)
  DEALLOCATE(O,Of,Ol,d,u,dAll,dfAll,dlAll)

  CALL MPI_FINALIZE(ierr)

2000 FORMAT ("# ----------------------------------------------------------------------------")
     
CONTAINS

#ifdef NETCDF
  !-----------------------------------------------------------------------
  !> subroutine exportGreensNetcdf
  ! initializes the coordinates of netcdf files
  !----------------------------------------------------------------------
  SUBROUTINE exportGreensNetcdf(M)
    REAL*8, INTENT(IN), DIMENSION(:,:) :: M

    REAL*8, DIMENSION(:), ALLOCATABLE :: x,y

    INTEGER :: i,ierr
    CHARACTER(LEN=256) :: filename

    ALLOCATE(x(SIZE(M,1)),y(SIZE(M,2)),STAT=ierr)
    IF (ierr/=0) STOP "could not allocate netcdf coordinate for Greens function"

    ! coordinates
    DO i=1,SIZE(M,1)
       x(i)=REAL(i,8)
    END DO
    DO i=1,SIZE(M,2)
       y(i)=REAL(i,8)
    END DO

    ! netcdf file is compatible with GMT
    WRITE (filename,'(a,"/greens-",I4.4,".grd")') TRIM(in%greensFunctionDirectory),rank
    CALL writeNetcdf(filename,SIZE(M,1),x,SIZE(M,2),y,M,1)

    DEALLOCATE(x,y)

  END SUBROUTINE exportGreensNetcdf
#endif

#ifdef NETCDF
  !-----------------------------------------------------------------------
  !> subroutine initnc
  ! initializes the coordinates of netcdf files
  !----------------------------------------------------------------------
  SUBROUTINE initnc()

    REAL*8, DIMENSION(:), ALLOCATABLE :: x

    INTEGER :: i,ierr
    CHARACTER(LEN=256) :: filename

    IF (0 .EQ. rank) THEN

       ! initialize the number of exports
       ncCount = 0

       ALLOCATE(x(in%nPatch),STAT=ierr)
       IF (ierr/=0) STOP "could not allocate netcdf coordinate"

       ! loop over all patch elements
       DO i=1,in%nPatch
          x(i)=REAL(i,8)
       END DO

       ! netcdf file is compatible with GMT
       WRITE (filename,'(a,"/log10v.grd")') TRIM(in%wdir)
       CALL openNetcdfUnlimited(filename,in%nPatch,x,ncid,y_varid,z_varid)

       DEALLOCATE(x)

    END IF

  END SUBROUTINE initnc
#endif

#ifdef NETCDF
  !-----------------------------------------------------------------------
  !> subroutine exportnc
  ! export time series of log10(v)
  !----------------------------------------------------------------------
  SUBROUTINE exportnc(n)
    INTEGER, INTENT(IN) :: n

    REAL*4, DIMENSION(n) :: z

    INTEGER :: j,l,ierr
    TYPE(PATCH_ELEMENT_STRUCT) :: patch

    ! update the export count
    ncCount=ncCount+1

    ! loop over all patch elements
    DO j=1,in%nPatch
       ! dip slip
       z(j)=REAL(LOG10(in%patch%s(j)%Vpl+vAll(DGF_PATCH*(j-1)+1)),4)
    END DO

    CALL writeNetcdfUnlimited(ncid,y_varid,z_varid,ncCount,n,z)

  END SUBROUTINE exportnc
#endif

  !-----------------------------------------------------------------------
  !> subroutine exportPoints
  ! export observation points
  !----------------------------------------------------------------------
  SUBROUTINE exportPoints()

    IMPLICIT NONE

    INTEGER :: i,k,l,ierr
    INTEGER :: elementIndex,elementType
    CHARACTER(2014) :: formatString
    TYPE(PATCH_ELEMENT_STRUCT) :: patch
    TYPE(STRAINVOLUME_ELEMENT_STRUCT) :: volume

    !-----------------------------------------------------------------
    ! step 1/3 - gather the kinematics from the state vector
    !-----------------------------------------------------------------

    ! element index in d vector
    k=1
    ! element index in state vector
    l=1
    ! loop over elements owned by current thread
    DO i=1,SIZE(layout%elementIndex)
       elementType= layout%elementType(i)
       elementIndex=layout%elementIndex(i)

       SELECT CASE (elementType)
       CASE (FLAG_PATCH)

          patch=in%patch%s(elementIndex)

          ! strike slip
          u(k)=y(l+STATE_VECTOR_SLIP_DIP)

          l=l+in%dPatch

       CASE (FLAG_VOLUME)

          volume=in%strainVolume%s(elementIndex)

          ! strain components e22, e23 and e33
          u(k:k+layout%elementVelocityDGF(i)-1)=(/ &
                     y(l+STATE_VECTOR_E22), &
                     y(l+STATE_VECTOR_E23), &
                     y(l+STATE_VECTOR_E33) /)

          l=l+in%dVolume

       CASE DEFAULT
          WRITE(STDERR,'("wrong case: this is a bug.")')
          WRITE_DEBUG_INFO(-1)
          STOP -1
       END SELECT

       k=k+layout%elementVelocityDGF(i)
    END DO

    !-----------------------------------------------------------------
    ! step 2/3 - calculate the rate of traction and rate of stress
    !            master thread adds the contribution of all elemets
    !-----------------------------------------------------------------

    ! use the BLAS library to compute the matrix vector product
    CALL DGEMV("T",SIZE(O,1),SIZE(O,2), &
                1._8,O,SIZE(O,1),u,1,0.d0,d,1)

    CALL MPI_REDUCE(d,dAll,in%nObservationPoint*DISPLACEMENT_VECTOR_DGF, &
                    MPI_REAL8,MPI_SUM,0,MPI_COMM_WORLD,ierr)

    ! use the BLAS library to compute the matrix vector product
    CALL DGEMV("T",SIZE(Of,1),SIZE(Of,2), &
                1._8,Of,SIZE(Of,1),u,1,0.d0,d,1)

    CALL MPI_REDUCE(d,dfAll,in%nObservationPoint*DISPLACEMENT_VECTOR_DGF, &
                    MPI_REAL8,MPI_SUM,0,MPI_COMM_WORLD,ierr)

    ! use the BLAS library to compute the matrix vector product
    CALL DGEMV("T",SIZE(Ol,1),SIZE(Ol,2), &
                1._8,Ol,SIZE(Ol,1),u,1,0.d0,d,1)

    CALL MPI_REDUCE(d,dlAll,in%nObservationPoint*DISPLACEMENT_VECTOR_DGF, &
                    MPI_REAL8,MPI_SUM,0,MPI_COMM_WORLD,ierr)

    !-----------------------------------------------------------------
    ! step 3/3 - master thread writes to disk
    !-----------------------------------------------------------------

    IF (0 .EQ. rank) THEN
       formatString="(ES19.12E2 "
       DO i=1,DISPLACEMENT_VECTOR_DGF
          formatString=TRIM(formatString)//" ES19.12E2 ES19.12E2 ES19.12E2"
       END DO
       formatString=TRIM(formatString)//")"

       ! element index in d vector
       k=1
       DO i=1,in%nObservationPoint
          WRITE (in%observationPoint(i)%file,TRIM(formatString)) &
                  time, &
                  dAll (k:k+DISPLACEMENT_VECTOR_DGF-1), &
                  dfAll(k:k+DISPLACEMENT_VECTOR_DGF-1), &
                  dlAll(k:k+DISPLACEMENT_VECTOR_DGF-1)
          k=k+DISPLACEMENT_VECTOR_DGF
       END DO
    END IF

  END SUBROUTINE exportPoints

  !-----------------------------------------------------------------------
  !> subroutine export
  ! write the state variables of elements, either patch or volume, and 
  ! other information.
  !----------------------------------------------------------------------
  SUBROUTINE export()

    IMPLICIT NONE

    ! degrees of freedom
    INTEGER :: dgf

    ! counters
    INTEGER :: j,k

    ! index in state vector
    INTEGER :: index

    ! maximum strain rate and maximum velocity
    REAL*8 :: eMaxAll,vMaxAll

    ! format string
    CHARACTER(1024) :: formatString

    ! export observation state
    DO j=1,in%nObservationState
       IF ((in%observationState(j,1) .GE. layout%listOffset(rank+1)) .AND. &
           (in%observationState(j,1) .LT. layout%listOffset(rank+1)+layout%listElements(rank+1))) THEN

          SELECT CASE(layout%elementType(in%observationState(j,1)-layout%listOffset(rank+1)+1))
          CASE (FLAG_PATCH)
             dgf=in%dPatch
          CASE (FLAG_VOLUME)
             dgf=in%dVolume
          CASE DEFAULT
             WRITE(STDERR,'("wrong case: this is a bug.")')
             WRITE_DEBUG_INFO(-1)
             STOP -1
          END SELECT

          formatString="(ES19.12E2 "
          DO k=1,dgf
             formatString=TRIM(formatString)//" ES20.12E3 ES20.12E3"
          END DO
          formatString=TRIM(formatString)//")"

          index=layout%elementStateIndex(in%observationState(j,1)-layout%listOffset(rank+1)+1)-dgf
          WRITE (in%observationState(j,2),TRIM(formatString)) time, &
                    y(index+1:index+dgf), &
                 dydt(index+1:index+dgf)
       END IF
    END DO

    IF (0 .EQ. MOD(i,50)) THEN
       CALL MPI_REDUCE(eMax,eMaxAll,1,MPI_REAL8,MPI_MAX,0,MPI_COMM_WORLD,ierr)
       CALL MPI_REDUCE(vMax,vMaxAll,1,MPI_REAL8,MPI_MAX,0,MPI_COMM_WORLD,ierr)
    END IF

    IF (0 .EQ. rank) THEN
       WRITE(FPTIME,'(ES19.12E2,ES19.12E2)') time,dt_done
       IF (0 .EQ. MOD(i,50)) THEN
          WRITE(STDOUT,'(I9.9,ES19.12E2,ES19.12E2,2ES11.4E2)') i,time,dt_done,vMaxAll,eMaxAll
          CALL FLUSH(STDOUT)
       END IF
    END IF

  END SUBROUTINE export

  !-----------------------------------------------------------------------
  !> subroutine initStateVector
  ! initialize the state vector
  !
  ! INPUT:
  ! @param n - number of state elements own by current thread
  ! @param y - the state vector (segment owned by currect thread)
  !
  !----------------------------------------------------------------------
  SUBROUTINE initStateVector(n,y,in)

    IMPLICIT NONE

    INTEGER, INTENT(IN)   :: n
    REAL*8, INTENT(OUT)    :: y(n)
    TYPE(SIMULATION_STRUCT), INTENT(IN) :: in

    INTEGER :: i,l,ierr
    INTEGER :: elementType,elementIndex
    TYPE(PATCH_ELEMENT_STRUCT) :: patch
    TYPE(STRAINVOLUME_ELEMENT_STRUCT) :: volume

    ! norm of deviatoric strain tensor
    REAL*8 :: eps
    ! norm of deviatoric stress tensor
    REAL*8 :: tau
    ! isotropic strain
    REAL*8 :: ekk
    ! deviatoric strain components
    REAL*8 :: e22p,e33p
    ! stress components
    REAL*8 :: s22,s23,s33

    ! initialize state vector to zero
    y=ZERO

    ! element index in state vector
    l=1
    ! loop over elements owned by current thread
    DO i=1,SIZE(layout%elementIndex)
       elementType= layout%elementType(i)
       elementIndex=layout%elementIndex(i)

       SELECT CASE (elementType)
       CASE (FLAG_PATCH)

          patch=in%patch%s(elementIndex)

          ! dip slip
          y(l+STATE_VECTOR_SLIP_DIP) = ZERO

          ! traction in dip direction
          IF (0 .GE. patch%tau0) THEN
             y(l+STATE_VECTOR_TRACTION_DIP) = patch%sig*(patch%mu0+(patch%a-patch%b)*log(patch%Vpl/patch%Vo)) &
                                                      -patch%damping*patch%Vpl
          ELSE
             y(l+STATE_VECTOR_TRACTION_DIP) = patch%tau0
          END IF

          ! traction in normal direction
          y(l+STATE_VECTOR_TRACTION_NORMAL) = ZERO

          ! state variable log(theta Vo / L)
          y(l+STATE_VECTOR_STATE_1) = log(patch%L/patch%Vpl)/lg10

          ! slip velocity log(V/Vo)
          y(l+STATE_VECTOR_VELOCITY) = log(patch%Vpl*0.98d0)/lg10

          l=l+in%dPatch

       CASE (FLAG_VOLUME)

          volume=in%strainVolume%s(elementIndex)

          ! stress components s22, s23 and s33
          IF ((0._8 .EQ. in%strainVolume%s0(elementIndex)%s22) .AND. &
              (0._8 .EQ. in%strainVolume%s0(elementIndex)%s23) .AND. &
              (0._8 .EQ. in%strainVolume%s0(elementIndex)%s33)) THEN

             ! strain rate from nonlinear viscosity in Maxwell element
             ekk=volume%e22+volume%e33
             e22p=volume%e22-ekk/2
             e33p=volume%e33-ekk/2
             eps=SQRT((e22p**2+2._8*volume%e23**2+e33p**2)/2._8)

             IF ((ZERO .LT. eps) .AND. (ZERO .LT. volume%ngammadot0m)) THEN
                tau=(eps/volume%ngammadot0m*exp(volume%nQm/(volume%nRm*volume%To)))**(ONE/volume%npowerm)
                s22 = tau*e22p/eps
                s23 = tau*volume%e23/eps
                s33 = tau*e33p/eps
             ELSE
                s22 = 0._8
                s23 = 0._8
                s33 = 0._8
             END IF

          ELSE
             s22 = in%strainVolume%s0(elementIndex)%s22
             s23 = in%strainVolume%s0(elementIndex)%s23
             s33 = in%strainVolume%s0(elementIndex)%s33
          END IF

          ! stress components s22, s23 and s33
          y(l+STATE_VECTOR_S22) = s22
          y(l+STATE_VECTOR_S23) = s23
          y(l+STATE_VECTOR_S33) = s33

          ! strain components e22, e23 and e33
          y(l+STATE_VECTOR_E22) = 0._8
          y(l+STATE_VECTOR_E23) = 0._8
          y(l+STATE_VECTOR_E33) = 0._8

          l=l+in%dVolume

       CASE DEFAULT
          WRITE(STDERR,'("wrong case: this is a bug.")')
          WRITE_DEBUG_INFO(-1)
          STOP -1
       END SELECT

    END DO

  END SUBROUTINE initStateVector

  !-----------------------------------------------------------------------
  !> subroutine odefun
  ! evalutes the derivative of the state vector
  !
  ! @param n - number of state elements own by current thread
  ! @param m - degrees of freedom
  !
  ! DESCRIPTION:
  !   1- extract slip velocity and strain rate from state vector
  !   2- calculate the rate of traction and rate of stress
  !   3- calculate the rate of remaining state variables
  !----------------------------------------------------------------------
  SUBROUTINE odefun(n,time,y,dydt)

    IMPLICIT NONE

    INTEGER, INTENT(IN)   :: n
    REAL*8, INTENT(IN)    :: time
    REAL*8, INTENT(IN)    :: y(n)
    REAL*8, INTENT(INOUT) :: dydt(n)

    INTEGER :: i,j,k,l,ierr
    INTEGER :: elementType,elementIndex
    TYPE(PATCH_ELEMENT_STRUCT) :: patch
    TYPE(STRAINVOLUME_ELEMENT_STRUCT) :: volume

    ! isotropic strain
    REAL*8 :: ekk

    ! isotropic stress
    REAL*8 :: p

    ! anelastic strain components
    REAL*8 :: e22,e23,e33

    ! stress components
    REAL*8 :: s22,s23,s33

    ! deviatoric stress components
    REAL*8 :: s22p,s33p

    ! norm of strain tensor
    REAL*8 :: eII

    ! norm of stress tensor
    REAL*8 :: sII

    ! scalar rate of shear traction
    REAL*8 :: dtau

    ! slip velocity in the dip direction
    REAL*8 :: velocity

    ! normal stress
    REAL*8 :: sigma

    ! Poisson s ratio
    REAL*8 :: nu

    nu = in%lambda/(in%lambda+in%mu)/2._8

    ! zero out rate of state vector
    dydt=ZERO

    ! maximum strain rate
    eMax=0._8

    ! maximum velocity
    vMax=0._8

    !--------------------------------------------------------------------
    ! step 1/3 - extract slip velocity and strain rate from state vector
    !--------------------------------------------------------------------

    ! element index in v vector
    k=1
    ! element index in state vector
    l=1
    ! loop over elements owned by current thread
    DO i=1,SIZE(layout%elementIndex)
       elementType= layout%elementType(i)
       elementIndex=layout%elementIndex(i)

       SELECT CASE (elementType)
       CASE (FLAG_PATCH)
          ! v(k:k+layout%elementVelocityDGF(i)-1) = slip velocity

          patch=in%patch%s(elementIndex)

          ! slip velocity
          velocity=EXP(y(l+STATE_VECTOR_VELOCITY)*lg10)

          ! update state vector (rate of slip)
          dydt(l+STATE_VECTOR_SLIP_DIP)=velocity

          v(k)=velocity-patch%Vpl

          l=l+in%dPatch

       CASE (FLAG_VOLUME)
          ! v(k:k+layout%elementVelocityDGF(i)-1)= strain rate

          volume=in%strainVolume%s(elementIndex)

          ! stress components
          s22=y(l+STATE_VECTOR_S22)
          s23=y(l+STATE_VECTOR_S23)
          s33=y(l+STATE_VECTOR_S33)

          ! isotropic stress
          p=(s22+s33)/2._8

          ! deviatoric stress
          s22p=s22-p
          s33p=s33-p

          ! deviatoric stress
          sII=SQRT((s22p**2+2._8*s23**2+s33p**2)/2._8)

          ! strain rate from nonlinear viscosity in Maxwell element
          eII=volume%ngammadot0m*sII**(volume%npowerm-1) &
                                *exp(-volume%nQm/(volume%nRm*volume%To))

          ! anelastic strain rate components
          e22=eII*s22p
          e23=eII*s23
          e33=eII*s33p

          ! update state vector (total anelastic strain)
          dydt(l+STATE_VECTOR_E22)=e22
          dydt(l+STATE_VECTOR_E23)=e23
          dydt(l+STATE_VECTOR_E33)=e33

          ! maximum strain rate
          eMax=MAX(eMax,SQRT((e22**2+2._8*e23**2+e33**2)/2._8))

          v(k:k+layout%elementVelocityDGF(i)-1)=(/ &
                  (e22-volume%e22)*1d3, &
                  (e23-volume%e23)*1d3, &
                  (e33-volume%e33)*1d3 /)

          l=l+in%dVolume

       CASE DEFAULT
          WRITE(STDERR,'("wrong case: this is a bug.")')
          WRITE_DEBUG_INFO(-1)
          STOP -1
       END SELECT

       k=k+layout%elementVelocityDGF(i)
    END DO

    ! all threads gather velocity from all threads
    CALL MPI_ALLGATHERV(v,layout%listVelocityN(1+rank),MPI_REAL8, &
                        vAll,layout%listVelocityN,layout%listVelocityOffset,MPI_REAL8, &
                        MPI_COMM_WORLD,ierr)

    !-----------------------------------------------------------------
    ! step 2/3 - calculate the rate of traction and rate of stress
    !-----------------------------------------------------------------

    ! use the BLAS library to compute the matrix vector product
    CALL DGEMV("T",SIZE(G,1),SIZE(G,2), &
                ONE,G,SIZE(G,1),vAll,1,ZERO,t,1)

    !-----------------------------------------------------------------
    ! step 3/3 - calculate the rate of remaining state variables
    !-----------------------------------------------------------------

    ! element index in t vector
    j=1
    ! element index in state vector
    l=1
    ! loop over elements owned by current thread
    DO i=1,SIZE(layout%elementIndex)
       elementType= layout%elementType(i)
       elementIndex=layout%elementIndex(i)

       SELECT CASE (elementType)
       CASE (FLAG_PATCH)

          patch=in%patch%s(elementIndex)

          ! slip velocity
          velocity=EXP(y(l+STATE_VECTOR_VELOCITY)*lg10)

          ! maximum velocity
          vMax=MAX(velocity,vMax)

          ! rate of state
          dydt(l+STATE_VECTOR_STATE_1)=(EXP(-y(l+STATE_VECTOR_STATE_1)*lg10)-velocity/patch%L)/lg10

          ! scalar rate of shear traction
          dtau=t(j+TRACTION_VECTOR_DIP)
       
          ! normal stress
          sigma=patch%sig!+y(l+STATE_VECTOR_TRACTION_NORMAL)

          ! acceleration
          dydt(l+STATE_VECTOR_VELOCITY)=(dtau-patch%b*sigma*dydt(l+STATE_VECTOR_STATE_1)*lg10) / &
                    (patch%a*sigma+patch%damping*velocity) / lg10

          ! return the traction rate
          dydt(l+STATE_VECTOR_TRACTION_DIP)=dtau-patch%damping*velocity*dydt(l+STATE_VECTOR_VELOCITY)*lg10

          ! rate of traction in the normal direction
          dydt(l+STATE_VECTOR_TRACTION_NORMAL)=t(j+TRACTION_VECTOR_NORMAL)

          l=l+in%dPatch

       CASE (FLAG_VOLUME)

          ! stress rate
          dydt(l+STATE_VECTOR_S22)=t(j+TRACTION_VECTOR_S22)
          dydt(l+STATE_VECTOR_S23)=t(j+TRACTION_VECTOR_S23)
          dydt(l+STATE_VECTOR_S33)=t(j+TRACTION_VECTOR_S33)

          l=l+in%dVolume

       CASE DEFAULT
          WRITE(STDERR,'("wrong case: this is a bug.")')
          WRITE_DEBUG_INFO(-1)
          STOP -1
       END SELECT

       j=j+layout%elementForceDGF(i)

    END DO

  END SUBROUTINE odefun

  !-----------------------------------------------------------------------
  !> subroutine initParallelism()
  !! initialize variables describe the data layout
  !! for parallelism.
  !!
  !! OUTPUT:
  !! layout    - list of receiver type and type index
  !-----------------------------------------------------------------------
  SUBROUTINE initParallelism(in,layout)
    IMPLICIT NONE
    TYPE(SIMULATION_STRUCT), INTENT(IN) :: in
    TYPE(LAYOUT_STRUCT), INTENT(OUT) :: layout

    ! MPI rank and size
    INTEGER :: rank,csize

    ! error flag
    INTEGER :: ierr

    INTEGER :: i,j,k,n,remainder,cumulativeIndex
    INTEGER :: nElements,nColumns
    INTEGER :: buffer

    CALL MPI_COMM_RANK(MPI_COMM_WORLD,rank,ierr)
    CALL MPI_COMM_SIZE(MPI_COMM_WORLD,csize,ierr)

    ! total number of elements
    nElements=in%patch%ns+in%strainVolume%ns

    ! list of number of elements in thread
    ALLOCATE(layout%listElements(csize), &
             layout%listOffset(csize),STAT=ierr)
    IF (ierr>0) STOP "could not allocate the list"

    remainder=nElements-INT(nElements/csize)*csize
    IF (0 .LT. remainder) THEN
       layout%listElements(1:(csize-remainder))      =INT(nElements/csize)
       layout%listElements((csize-remainder+1):csize)=INT(nElements/csize)+1
    ELSE
       layout%listElements(1:csize)=INT(nElements/csize)
    END IF

    ! element start index in thread
    j=0
    k=0
    DO i=1,csize
       j=k+1
       k=k+layout%listElements(i)
       layout%listOffset(i)=j
    END DO

    ALLOCATE(layout%elementType       (layout%listElements(1+rank)), &
             layout%elementIndex      (layout%listElements(1+rank)), &
             layout%elementStateIndex (layout%listElements(1+rank)), &
             layout%elementVelocityDGF(layout%listElements(1+rank)), &
             layout%elementStateDGF   (layout%listElements(1+rank)), &
             layout%elementForceDGF   (layout%listElements(1+rank)),STAT=ierr)
    IF (ierr>0) STOP "could not allocate the layout elements"

    j=1
    cumulativeIndex=0
    DO i=1,in%patch%ns
       IF ((i .GE. layout%listOffset(1+rank)) .AND. &
           (i .LT. (layout%listOffset(1+rank)+layout%listElements(1+rank)))) THEN
          layout%elementType(j)=FLAG_PATCH
          layout%elementIndex(j)=i
          layout%elementStateIndex(j)=cumulativeIndex+STATE_VECTOR_DGF_PATCH
          cumulativeIndex=layout%elementStateIndex(j)
          layout%elementVelocityDGF(j)=DGF_PATCH
          layout%elementStateDGF(j)=in%dPatch
          layout%elementForceDGF(j)=DGF_VECTOR
          j=j+1
       END IF
    END DO

    DO i=1,in%strainVolume%ns
       IF (((i+in%patch%ns) .GE. layout%listOffset(1+rank)) .AND. &
           ((i+in%patch%ns) .LT. (layout%listOffset(1+rank)+layout%listElements(1+rank)))) THEN
          layout%elementType(j)=FLAG_VOLUME
          layout%elementIndex(j)=i
          layout%elementStateIndex(j)=cumulativeIndex+STATE_VECTOR_DGF_VOLUME
          cumulativeIndex=layout%elementStateIndex(j)
          layout%elementVelocityDGF(j)=DGF_VOLUME
          layout%elementStateDGF(j)=in%dVolume
          layout%elementForceDGF(j)=DGF_TENSOR
          j=j+1
       END IF
    END DO

    ALLOCATE(layout%listVelocityN(csize), &
             layout%listVelocityOffset(csize), &
             layout%listStateN(csize), &
             layout%listStateOffset(csize), &
             layout%listForceN(csize), &
             STAT=ierr)
    IF (ierr>0) STOP "could not allocate the size list"

    ! share number of elements in threads
    CALL MPI_ALLGATHER(SUM(layout%elementVelocityDGF),1,MPI_INTEGER,layout%listVelocityN,1,MPI_INTEGER,MPI_COMM_WORLD,ierr)
    CALL MPI_ALLGATHER(SUM(layout%elementStateDGF),   1,MPI_INTEGER,layout%listStateN,   1,MPI_INTEGER,MPI_COMM_WORLD,ierr)
    CALL MPI_ALLGATHER(SUM(layout%elementForceDGF),   1,MPI_INTEGER,layout%listForceN,   1,MPI_INTEGER,MPI_COMM_WORLD,ierr)

    j=0
    k=0
    DO i=1,csize
       j=k+1
       k=k+layout%listVelocityN(i)
       layout%listVelocityOffset(i)=j-1
    END DO

    j=0
    k=0
    DO i=1,csize
       j=k+1
       k=k+layout%listStateN(i)
       layout%listStateOffset(i)=j-1
    END DO

  END SUBROUTINE initParallelism

  !-----------------------------------------------------------------------
  !> subroutine initGeometry
  ! initializes the position and local reference system vectors
  !
  ! INPUT:
  ! @param in      - input parameters data structure
  !-----------------------------------------------------------------------
  SUBROUTINE initGeometry(in)
    USE planestrain
    USE types
    TYPE(SIMULATION_STRUCT), INTENT(INOUT) :: in
  
    IF (0 .LT. in%patch%ns) THEN
       CALL computeReferenceSystemPlaneStrain( &
                in%patch%ns, &
                in%patch%x, &
                in%patch%width, &
                in%patch%dip, &
                in%patch%sv, &
                in%patch%dv, &
                in%patch%nv, &
                in%patch%xc)
    END IF

    IF (0 .LT. in%strainVolume%ns) THEN
       CALL computeReferenceSystemPlaneStrain( &
                in%strainVolume%ns, &
                in%strainVolume%x, &
                in%strainVolume%width, &
                in%strainVolume%dip, &
                in%strainVolume%sv, &
                in%strainVolume%dv, &
                in%strainVolume%nv, &
                in%strainVolume%xc)
    END IF

  END SUBROUTINE initGeometry

  !---------------------------------------------------------------------
  !> subroutine init
  !! reads simulation parameters from the standard input and initialize
  !! model parameters.
  !!
  !! INPUT:
  !! @param unit - the unit number used to read input data
  !!
  !! OUTPUT:
  !! @param in
  !!
  !! \author Sylvain Barbot (sbarbot@ntu.edu.sg)
  !---------------------------------------------------------------------
  SUBROUTINE init(in)
    USE types
    USE getopt_m
  
    TYPE(SIMULATION_STRUCT), INTENT(OUT) :: in
  
    INCLUDE 'mpif.h'
  
    CHARACTER :: ch
    CHARACTER(512) :: dataline
    CHARACTER(256) :: filename
    INTEGER :: iunit,noptions
!$  INTEGER :: omp_get_num_procs,omp_get_max_threads
    TYPE(OPTION_S) :: opts(8)
  
    INTEGER :: k,ierr,i,rank,size,position
    INTEGER, PARAMETER :: psize=1024
    INTEGER :: dummy
    CHARACTER, DIMENSION(psize) :: packed

    INTEGER :: nObservationPatch,nObservationVolume
    INTEGER, DIMENSION(:), ALLOCATABLE :: observationPatch,observationVolume
  
    CALL MPI_COMM_RANK(MPI_COMM_WORLD,rank,ierr)
    CALL MPI_COMM_SIZE(MPI_COMM_WORLD,size,ierr)
  
    ! define long options, such as --dry-run
    ! parse the command line for options
    opts(1)=OPTION_S("version",.FALSE.,CHAR(21))
    opts(2)=OPTION_S("dry-run",.FALSE.,CHAR(22))
    opts(3)=OPTION_S("epsilon",.TRUE.,'e')
    opts(4)=OPTION_S("export-greens",.TRUE.,'g')
    opts(5)=OPTION_S("export-netcdf",.FALSE.,'n')
    opts(6)=OPTION_S("maximum-step",.TRUE.,'m')
    opts(7)=OPTION_S("maximum-iterations",.TRUE.,'i')
    opts(8)=OPTION_S("help",.FALSE.,'h')
  
    noptions=0;
    DO
       ch=getopt("he:g:i:m:n",opts)
       SELECT CASE(ch)
       CASE(CHAR(0))
          EXIT
       CASE(CHAR(21))
          ! option version
          in%isversion=.TRUE.
       CASE(CHAR(22))
          ! option dry-run
          in%isdryrun=.TRUE.
       CASE('e')
          ! numerical accuracy (variable epsilon sits in the ode45 module)
          READ(optarg,*) epsilon
          noptions=noptions+1
       CASE('g')
          ! export Greens functions to netcdf file
          READ(optarg,'(a)') in%greensFunctionDirectory
          in%isexportgreens=.TRUE.
          noptions=noptions+1
       CASE('i')
          ! maximum iterations
          READ(optarg,*) maximumIterations
          noptions=noptions+1
       CASE('m')
          ! maximum time step (variable maximumTimeStep sits in the ode45 module)
          READ(optarg,*) maximumTimeStep
          noptions=noptions+1
       CASE('n')
          ! export in netcdf format
          in%isexportnetcdf=.TRUE.
       CASE('h')
          ! option help
          in%ishelp=.TRUE.
       CASE('?')
          WRITE_DEBUG_INFO(100)
          in%ishelp=.TRUE.
          EXIT
       CASE DEFAULT
          WRITE (0,'("unhandled option ", a, " (this is a bug")') optopt
          WRITE_DEBUG_INFO(100)
          STOP 3
       END SELECT
       noptions=noptions+1
    END DO
  
    IF (in%isversion) THEN
       CALL printversion()
       ! abort parameter input
       STOP
    END IF
  
    IF (in%ishelp) THEN
       CALL printhelp()
       ! abort parameter input
       STOP
    END IF
  
    ! number of fault patches
    in%nPatch=0
    ! number of dynamic variables for patches
    in%dPatch=STATE_VECTOR_DGF_PATCH
    ! number of strain volumes
    in%nVolume=0
    ! number of dynamic variables for strain volumes (s22,s23,s33,e22,e23,e33)
    in%dVolume=STATE_VECTOR_DGF_VOLUME
    in%patch%ns=0
    in%strainVolume%ns=0
  
    IF (0 .EQ. rank) THEN
       PRINT 2000
       PRINT '("# VISCOUSCYCLES")'
       PRINT '("# quasi-dynamic earthquake simulation in viscoelastic medium")'
       PRINT '("# in condition of plane strain with the radiation damping")'
       PRINT '("# approximation.")'
       PRINT '("# numerical accuracy: ",ES11.4)', epsilon
       PRINT '("# maximum iterations: ",I11)', maximumIterations
       PRINT '("# maximum time step: ",ES12.4)', maximumTimeStep
       PRINT '("# number of threads: ",I12)', csize
       IF (in%isexportnetcdf) THEN
          PRINT '("# export velocity to netcdf:  yes")'
       ELSE
          PRINT '("# export velocity to netcdf:   no")'
       END IF
       IF (in%isexportgreens) THEN
          PRINT '("# export greens function:     yes")'
       END IF
!$     PRINT '("#     * parallel OpenMP implementation with ",I3.3,"/",I3.3," threads")', &
!$                omp_get_max_threads(),omp_get_num_procs()
       PRINT 2000
  
       IF (noptions .LT. COMMAND_ARGUMENT_COUNT()) THEN
          ! read from input file
          iunit=25
          CALL GET_COMMAND_ARGUMENT(noptions+1,filename)
          OPEN (UNIT=iunit,FILE=filename,IOSTAT=ierr)
       ELSE
          ! get input parameters from standard input
          iunit=5
       END IF
  
       PRINT '("# output directory")'
       CALL getdata(iunit,dataline)
       READ (dataline,'(a)') in%wdir
       PRINT '(2X,a)', TRIM(in%wdir)
  
       in%timeFilename=TRIM(in%wdir)//"/time.txt"
  
       ! test write permissions on output directory
       OPEN (UNIT=FPTIME,FILE=in%timeFilename,POSITION="APPEND",&
               IOSTAT=ierr,FORM="FORMATTED")
       IF (ierr>0) THEN
          WRITE_DEBUG_INFO(102)
          WRITE (STDERR,'("error: unable to access ",a)') TRIM(in%timefilename)
          STOP 1
       END IF
       CLOSE(FPTIME)
     
       PRINT '("# elastic moduli")'
       CALL getdata(iunit,dataline)
       READ  (dataline,*) in%mu,in%lambda
       PRINT '(2ES9.2E1)', in%mu,in%lambda
  
       IF (0 .GT. in%mu) THEN
          WRITE_DEBUG_INFO(-1)
          WRITE (STDERR,'(a)') TRIM(dataline)
          WRITE (STDERR,'("input error: shear modulus must be positive")')
          STOP -1
       END IF
  
       PRINT '("# time interval")'
       CALL getdata(iunit,dataline)
       READ  (dataline,*) in%interval
       PRINT '(ES20.12E2)', in%interval
  
       IF (in%interval .LE. ZERO) THEN
          WRITE (STDERR,'("**** error **** ")')
          WRITE (STDERR,'(a)') TRIM(dataline)
          WRITE (STDERR,'("simulation time must be positive. exiting.")')
          STOP 1
       END IF
  
       ! - - - - - - - - - - - - - - - - - - - - - - - - - -
       !                   P A T C H E S
       ! - - - - - - - - - - - - - - - - - - - - - - - - - -
       PRINT '("# number of patches")'
       CALL getdata(iunit,dataline)
       READ  (dataline,*) in%patch%ns
       PRINT '(I5)', in%patch%ns
       IF (in%patch%ns .GT. 0) THEN
          ALLOCATE(in%patch%s(in%patch%ns), &
                   in%patch%x(3,in%patch%ns), &
                   in%patch%xc(3,in%patch%ns), &
                   in%patch%width(in%patch%ns), &
                   in%patch%dip(in%patch%ns), &
                   in%patch%sv(3,in%patch%ns), &
                   in%patch%dv(3,in%patch%ns), &
                   in%patch%nv(3,in%patch%ns),STAT=ierr)
          IF (ierr>0) STOP "could not allocate the patch list"
          PRINT 2000
          PRINT '("# n       Vpl       x2       x3    width    dip")'
          PRINT 2000
          DO k=1,in%patch%ns
             CALL getdata(iunit,dataline)
             READ (dataline,*,IOSTAT=ierr) i, &
                  in%patch%s(k)%Vpl, &
                  in%patch%x(2,k), &
                  in%patch%x(3,k), &
                  in%patch%width(k), &
                  in%patch%dip(k)
   
             PRINT '(I3.3,ES10.2E2,2ES9.2E1,2ES8.2E1)',i, &
                  in%patch%s(k)%Vpl, &
                  in%patch%x(2,k), &
                  in%patch%x(3,k), &
                  in%patch%width(k), &
                  in%patch%dip(k)
                
             ! convert to radians
             in%patch%dip(k)=in%patch%dip(k)*DEG2RAD     

             IF (i .NE. k) THEN
                WRITE (STDERR,'("invalid patch definition")')
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE (STDERR,'("error in input file: unexpected index")')
                STOP 1
             END IF
             IF (in%patch%width(k) .LE. ZERO) THEN
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE (STDERR,'("error in input file: patch width must be positive.")')
                STOP 1
             END IF
                
          END DO
   
          ! - - - - - - - - - - - - - - - - - - - - - - - - - -
          !        F R I C T I O N   P R O P E R T I E S
          ! - - - - - - - - - - - - - - - - - - - - - - - - - -
          PRINT 2000
          PRINT '("# number of frictional patches")'
          CALL getdata(iunit,dataline)
          READ  (dataline,*) dummy
          PRINT '(I5)', dummy
          IF (dummy .NE. in%patch%ns) THEN
             WRITE_DEBUG_INFO(-1)
             WRITE (STDERR,'(a)') TRIM(dataline)
             WRITE(STDERR,'("input error: all patches require frictional properties")')
             STOP -1
          END IF
          PRINT '("#  n     tau0      mu0      sig        a        b        L       Vo  G/(2Vs)")'
          PRINT 2000
          DO k=1,in%patch%ns
             CALL getdata(iunit,dataline)
             READ (dataline,*,IOSTAT=ierr) i, &
                   in%patch%s(k)%tau0, &
                   in%patch%s(k)%mu0, &
                   in%patch%s(k)%sig, &
                   in%patch%s(k)%a, &
                   in%patch%s(k)%b, &
                   in%patch%s(k)%L, &
                   in%patch%s(k)%Vo, &
                   in%patch%s(k)%damping
   
             PRINT '(I4,8ES9.2E1)',i, &
                  in%patch%s(k)%tau0, &
                  in%patch%s(k)%mu0, &
                  in%patch%s(k)%sig, &
                  in%patch%s(k)%a, &
                  in%patch%s(k)%b, &
                  in%patch%s(k)%L, &
                  in%patch%s(k)%Vo, &
                  in%patch%s(k)%damping
                
             IF (i .NE. k) THEN
                WRITE_DEBUG_INFO(200)
                WRITE (STDERR,'("invalid friction property definition for patch")')
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE (STDERR,'("error in input file: unexpected index")')
                STOP 1
             END IF
          END DO
   
       END IF
          
       ! - - - - - - - - - - - - - - - - - - - - - - - - - -
       !       S T R A I N   V O L U M E S
       ! - - - - - - - - - - - - - - - - - - - - - - - - - -
       PRINT '("# number of cuboid strain volumes")'
       CALL getdata(iunit,dataline)
       READ  (dataline,*) in%strainVolume%ns
       PRINT '(I5)', in%strainVolume%ns
       IF (in%strainVolume%ns .GT. 0) THEN
          ALLOCATE(in%strainVolume%s(in%strainVolume%ns), &
                   in%strainVolume%x(3,in%strainVolume%ns), &
                   in%strainVolume%xc(3,in%strainVolume%ns), &
                   in%strainVolume%width(in%strainVolume%ns), &
                   in%strainVolume%thickness(in%strainVolume%ns), &
                   in%strainVolume%dip(in%strainVolume%ns), &
                   in%strainVolume%sv(3,in%strainVolume%ns), &
                   in%strainVolume%dv(3,in%strainVolume%ns), &
                   in%strainVolume%nv(3,in%strainVolume%ns),STAT=ierr)
          IF (ierr>0) STOP "could not allocate the strain volume list"
          PRINT 2000
          PRINT '("# n       e22       e23       e33       x2       x3   ", &
                & "width thickness  dip")'
          PRINT 2000
          DO k=1,in%strainVolume%ns
             CALL getdata(iunit,dataline)
             READ (dataline,*,IOSTAT=ierr) i, &
                  in%strainVolume%s(k)%e22, &
                  in%strainVolume%s(k)%e23, &
                  in%strainVolume%s(k)%e33, &
                  in%strainVolume%x(2,k), &
                  in%strainVolume%x(3,k), &
                  in%strainVolume%width(k), &
                  in%strainVolume%thickness(k), &
                  in%strainVolume%dip(k)
   
             PRINT '(I3.3,3ES10.2E2,2ES9.2E1,2ES8.2E1,f7.1)',i, &
                  in%strainVolume%s(k)%e22, &
                  in%strainVolume%s(k)%e23, &
                  in%strainVolume%s(k)%e33, &
                  in%strainVolume%x(2,k), &
                  in%strainVolume%x(3,k), &
                  in%strainVolume%width(k), &
                  in%strainVolume%thickness(k), &
                  in%strainVolume%dip(k)
                
             ! convert to radians
             in%strainVolume%dip(k)=in%strainVolume%dip(k)*DEG2RAD     

             IF (0 .GT. in%strainVolume%x(3,k)) THEN
                WRITE_DEBUG_INFO(-1)
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE (STDERR,'("input error: depth must be positive")')
                STOP -1
             END IF

             IF (i .NE. k) THEN
                WRITE (STDERR,'("invalid strain volume definition")')
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE (STDERR,'("input error: unexpected index")')
                STOP 1
             END IF
             IF (MIN(in%strainVolume%width(k),in%strainVolume%thickness(k)) .LE. ZERO) THEN
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE (STDERR,'("input error: strain volume dimension must be positive.")')
                STOP 1
             END IF
                
          END DO
   
          ! - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
          !   N O N L I N E A R   M A X W E L L   P R O P E R T I E S
          ! - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
          PRINT 2000
          PRINT '("# number of nonlinear Maxwell strain volumes")'
          CALL getdata(iunit,dataline)
          READ  (dataline,*) in%strainVolume%nNonlinearMaxwell
          PRINT '(I5)', in%strainVolume%nNonlinearMaxwell
          IF (0 .NE. in%strainVolume%nNonlinearMaxwell) THEN
             IF (in%strainVolume%ns .NE. in%strainVolume%nNonlinearMaxwell) THEN
                WRITE_DEBUG_INFO(-1)
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE(STDERR,'("input error: nonlinear Maxwell properties ", &
                             & "are for none or all strain volumes")')
                STOP -1
             END IF
             ALLOCATE(in%strainVolume%s0(in%strainVolume%ns),STAT=ierr)
             IF (ierr>0) STOP "could not allocate the strain volume initial stress"

             PRINT '("# n      s22      s23      s33          Gm  gammadot0m        n        Q        R")'
             PRINT 2000
             DO k=1,in%strainVolume%ns
                CALL getdata(iunit,dataline)
                READ (dataline,*,IOSTAT=ierr) i, &
                      in%strainVolume%s0(k)%s22, &
                      in%strainVolume%s0(k)%s23, &
                      in%strainVolume%s0(k)%s33, &
                      in%strainVolume%s(k)%ngammadot0m, &
                      in%strainVolume%s(k)%npowerm, &
                      in%strainVolume%s(k)%nQm, &
                      in%strainVolume%s(k)%nRm
   
                PRINT '(I3.3,3ES9.2E1,ES12.4E2,3ES9.2E1)',i, &
                      in%strainVolume%s0(k)%s22, &
                      in%strainVolume%s0(k)%s23, &
                      in%strainVolume%s0(k)%s33, &
                      in%strainVolume%s(k)%ngammadot0m, &
                      in%strainVolume%s(k)%npowerm, &
                      in%strainVolume%s(k)%nQm, &
                      in%strainVolume%s(k)%nRm
                
                IF (0 .GE. in%strainVolume%s(k)%nRm) THEN
                   WRITE_DEBUG_INFO(200)
                   WRITE (STDERR,'(a)') TRIM(dataline)
                   WRITE (STDERR,'("invalid property definition for strain volume")')
                   WRITE (STDERR,'("error in input file: R must be positive.")')
                   STOP 1
                END IF

                IF (i .NE. k) THEN
                   WRITE_DEBUG_INFO(200)
                   WRITE (STDERR,'("invalid property definition for strain volume")')
                   WRITE (STDERR,'(a)') TRIM(dataline)
                   WRITE (STDERR,'("error in input file: unexpected index")')
                   STOP 1
                END IF
             END DO

          END IF
   
          ! - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
          !          T H E R M A L   P R O P E R T I E S
          ! - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
          PRINT 2000
          PRINT '("# number of thermal strain volumes")'
          CALL getdata(iunit,dataline)
          READ  (dataline,*) dummy
          PRINT '(I5)', dummy
          IF (0 .NE. dummy) THEN
             IF (in%strainVolume%ns .NE. dummy) THEN
                WRITE_DEBUG_INFO(-1)
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE(STDERR,'("input error: thermal properties ", &
                               "are for none or all strain volumes")')
                STOP -1
             END IF

             PRINT '("# n     rhoc  temperature")'
             PRINT 2000
             DO k=1,in%strainVolume%ns
                CALL getdata(iunit,dataline)
                READ (dataline,*,IOSTAT=ierr) i, &
                      in%strainVolume%s(k)%rhoc, &
                      in%strainVolume%s(k)%To
   
                PRINT '(I3.3,5ES11.4E1)',i, &
                      in%strainVolume%s(k)%rhoc, &
                      in%strainVolume%s(k)%To
                
                IF (0 .GE. in%strainVolume%s(k)%To) THEN
                   WRITE_DEBUG_INFO(200)
                   WRITE (STDERR,'(a)') TRIM(dataline)
                   WRITE (STDERR,'("invalid property definition for strain volume")')
                   WRITE (STDERR,'("error in input file: To must be positive.")')
                   STOP 1
                END IF

                IF (i .NE. k) THEN
                   WRITE_DEBUG_INFO(200)
                   WRITE (STDERR,'(a)') TRIM(dataline)
                   WRITE (STDERR,'("invalid property definition for strain volume")')
                   WRITE (STDERR,'("error in input file: unexpected index")')
                   STOP 1
                END IF
             END DO

          END IF
   
       END IF
          
       ! - - - - - - - - - - - - - - - - - - - - - - - - - -
       !       O B S E R V A T I O N   P A T C H E S
       ! - - - - - - - - - - - - - - - - - - - - - - - - - -
       PRINT 2000
       PRINT '("# number of observation patches")'
       CALL getdata(iunit,dataline)
       READ  (dataline,*) nObservationPatch
       PRINT '(I5)', nObservationPatch
       IF (0 .LT. nObservationPatch) THEN
          ALLOCATE(observationPatch(nObservationPatch),STAT=ierr)
          IF (ierr>0) STOP "could not allocate the observation patches"
          PRINT 2000
          PRINT '("# n      i")'
          PRINT 2000
          DO k=1,nObservationPatch
             CALL getdata(iunit,dataline)
             READ (dataline,*,IOSTAT=ierr) i,observationPatch(k)
             PRINT '(I3.3,X,I6)',i,observationPatch(k)
             IF (i .NE. k) THEN
                WRITE_DEBUG_INFO(200)
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE (STDERR,'("error in input file: unexpected index")')
                STOP 1
             END IF
          END DO
       END IF

       ! - - - - - - - - - - - - - - - - - - - - - - - - - -
       !       O B S E R V A T I O N   V O L U M E S
       ! - - - - - - - - - - - - - - - - - - - - - - - - - -
       PRINT 2000
       PRINT '("# number of observation volumes")'
       CALL getdata(iunit,dataline)
       READ  (dataline,*) nObservationVolume
       PRINT '(I5)', nObservationVolume
       IF (0 .LT. nObservationVolume) THEN
          ALLOCATE(observationVolume(nObservationVolume),STAT=ierr)
          IF (ierr>0) STOP "could not allocate the observation volumes0"
          PRINT 2000
          PRINT '("# n      i")'
          PRINT 2000
          DO k=1,nObservationVolume
             CALL getdata(iunit,dataline)
             READ (dataline,*,IOSTAT=ierr) i,observationVolume(k)
             PRINT '(I3.3,X,I6)',i,observationVolume(k)
             IF (i .NE. k) THEN
                WRITE_DEBUG_INFO(200)
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE (STDERR,'("error in input file: unexpected index")')
                STOP 1
             END IF
          END DO
       END IF

       ! - - - - - - - - - - - - - - - - - - - - - - - - - -
       !        O B S E R V A T I O N   P O I N T S
       ! - - - - - - - - - - - - - - - - - - - - - - - - - -
       PRINT 2000
       PRINT '("# number of observation points")'
       CALL getdata(iunit,dataline)
       READ  (dataline,*) in%nObservationPoint
       PRINT '(I5)', in%nObservationPoint
       IF (0 .LT. in%nObservationPoint) THEN
          ALLOCATE(in%observationPoint(in%nObservationPoint),STAT=ierr)
          IF (ierr>0) STOP "could not allocate the observation points"
          PRINT 2000
          PRINT '("# n name       x2       x3")'
          PRINT 2000
          DO k=1,in%nObservationPoint
             CALL getdata(iunit,dataline)
             READ (dataline,*,IOSTAT=ierr) i, &
                     in%observationPoint(k)%name, &
                     in%observationPoint(k)%x(2), &
                     in%observationPoint(k)%x(3)

             ! set along-strike coordinate to zero for 2d solutions
             in%observationPoint(k)%x(1)=0._8

             PRINT '(I3.3,X,a4,2ES9.2E1)',i, &
                     in%observationPoint(k)%name, &
                     in%observationPoint(k)%x(2), &
                     in%observationPoint(k)%x(3)

             IF (i .NE. k) THEN
                WRITE_DEBUG_INFO(200)
                WRITE (STDERR,'(a)') TRIM(dataline)
                WRITE (STDERR,'("error in input file: unexpected index")')
                STOP 1
             END IF
          END DO
       END IF

       ! test the presence of dislocations
       IF ((in%patch%ns .EQ. 0) .AND. &
           (in%interval .LE. ZERO)) THEN
   
          WRITE_DEBUG_INFO(300)
          WRITE (STDERR,'("nothing to do. exiting.")')
          STOP 1
       END IF
   
       PRINT 2000
       ! flush standard output
       CALL FLUSH(6)

       in%nObservationState=nObservationPatch+nObservationVolume
       ALLOCATE(in%observationState(in%nObservationState,2))
       j=1
       DO i=1,nObservationPatch
          in%observationState(j,1)=observationPatch(i)
          j=j+1
       END DO

       DO i=1,nObservationVolume
          in%observationState(j,1)=observationVolume(i)+in%patch%ns
          j=j+1
       END DO
       IF (ALLOCATED(observationPatch)) DEALLOCATE(observationPatch)
       IF (ALLOCATED(observationVolume)) DEALLOCATE(observationVolume)

       position=0
       CALL MPI_PACK(in%interval,         1,MPI_REAL8,  packed,psize,position,MPI_COMM_WORLD,ierr)
       CALL MPI_PACK(in%mu,               1,MPI_REAL8,  packed,psize,position,MPI_COMM_WORLD,ierr)
       CALL MPI_PACK(in%lambda,           1,MPI_REAL8,  packed,psize,position,MPI_COMM_WORLD,ierr)
       CALL MPI_PACK(in%patch%ns,         1,MPI_INTEGER,packed,psize,position,MPI_COMM_WORLD,ierr)
       CALL MPI_PACK(in%strainVolume%ns,  1,MPI_INTEGER,packed,psize,position,MPI_COMM_WORLD,ierr)
       CALL MPI_PACK(in%nObservationState,1,MPI_INTEGER,packed,psize,position,MPI_COMM_WORLD,ierr)
       CALL MPI_PACK(in%nObservationPoint,1,MPI_INTEGER,packed,psize,position,MPI_COMM_WORLD,ierr)
       CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)

       position=0
       CALL MPI_PACK(in%wdir,256,MPI_CHARACTER,packed,psize,position,MPI_COMM_WORLD,ierr)
       CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)

       ! send the patches (geometry and friction properties) 
       DO i=1,in%patch%ns
          position=0
          CALL MPI_PACK(in%patch%s(i)%Vpl,    1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%x(2,i),      1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%x(3,i),      1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%width(i),    1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%dip(i),      1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%s(i)%tau0,   1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%s(i)%mu0,    1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%s(i)%sig,    1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%s(i)%a,      1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%s(i)%b,      1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%s(i)%L,      1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%s(i)%Vo,     1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%patch%s(i)%damping,1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)
       END DO

       ! send the strain volumes
       DO i=1,in%strainVolume%ns
          position=0
          CALL MPI_PACK(in%strainVolume%s(i)%e22,        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%e23,        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%e33,        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%x(2,i),          1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%x(3,i),          1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%width(i),        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%thickness(i),    1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%dip(i),          1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%Gk,         1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%gammadot0k, 1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%dok,        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%mk,         1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%Qk,         1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%Rk,         1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%Gm,         1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%gammadot0m, 1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%dom,        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%mm,         1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%Qm,         1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%Rm,         1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%nGk,        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s0(i)%s22,       1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s0(i)%s23,       1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s0(i)%s33,       1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%ngammadot0k,1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%npowerk,    1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%nQk,        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%nRk,        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%ngammadot0m,1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%npowerm,    1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%nQm,        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%nRm,        1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%rhoc,       1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_PACK(in%strainVolume%s(i)%To,         1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)
       END DO

       ! send the observation state
       DO i=1,in%nObservationState
          position=0
          CALL MPI_PACK(in%observationState(i,1),1,MPI_INTEGER,packed,psize,position,MPI_COMM_WORLD,ierr)
          CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)
       END DO

       ! send the observation points
       DO i=1,in%nObservationPoint
          position=0
          CALL MPI_PACK(in%observationPoint(i)%name,10,MPI_CHARACTER,packed,psize,position,MPI_COMM_WORLD,ierr)
          DO k=1,3
             CALL MPI_PACK(in%observationPoint(i)%x(k),1,MPI_REAL8,packed,psize,position,MPI_COMM_WORLD,ierr)
          END DO
          CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)
       END DO

    ELSE ! IF 0 .NE. rank

       !------------------------------------------------------------------
       ! S L A V E S
       !------------------------------------------------------------------

       position=0
       CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)
       CALL MPI_UNPACK(packed,psize,position,in%interval,         1,MPI_REAL8,  MPI_COMM_WORLD,ierr)
       CALL MPI_UNPACK(packed,psize,position,in%mu,               1,MPI_REAL8,  MPI_COMM_WORLD,ierr)
       CALL MPI_UNPACK(packed,psize,position,in%lambda,           1,MPI_REAL8,  MPI_COMM_WORLD,ierr)
       CALL MPI_UNPACK(packed,psize,position,in%patch%ns,         1,MPI_INTEGER,MPI_COMM_WORLD,ierr)
       CALL MPI_UNPACK(packed,psize,position,in%strainVolume%ns,  1,MPI_INTEGER,MPI_COMM_WORLD,ierr)
       CALL MPI_UNPACK(packed,psize,position,in%nObservationState,1,MPI_INTEGER,MPI_COMM_WORLD,ierr)
       CALL MPI_UNPACK(packed,psize,position,in%nObservationPoint,1,MPI_INTEGER,MPI_COMM_WORLD,ierr)

       position=0
       CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)
       CALL MPI_UNPACK(packed,psize,position,in%wdir,256,MPI_CHARACTER,MPI_COMM_WORLD,ierr)

       IF (0 .LT. in%patch%ns) &
                    ALLOCATE(in%patch%s(in%patch%ns), &
                             in%patch%x(3,in%patch%ns), &
                             in%patch%xc(3,in%patch%ns), &
                             in%patch%width(in%patch%ns), &
                             in%patch%dip(in%patch%ns), &
                             in%patch%sv(3,in%patch%ns), &
                             in%patch%dv(3,in%patch%ns), &
                             in%patch%nv(3,in%patch%ns), &
                             STAT=ierr)
       IF (ierr>0) STOP "slave could not allocate memory for patches"

       DO i=1,in%patch%ns
          position=0
          CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%s(i)%Vpl,    1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%x(2,i),      1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%x(3,i),      1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%width(i),    1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%dip(i),      1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%s(i)%tau0,   1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%s(i)%mu0,    1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%s(i)%sig,    1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%s(i)%a,      1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%s(i)%b,      1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%s(i)%L,      1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%s(i)%Vo,     1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%patch%s(i)%damping,1,MPI_REAL8,MPI_COMM_WORLD,ierr)
       END DO

       IF (0 .LT. in%strainVolume%ns) &
                    ALLOCATE(in%strainVolume%s(in%strainVolume%ns), &
                             in%strainVolume%s0(in%strainVolume%ns), &
                             in%strainVolume%x(3,in%strainVolume%ns), &
                             in%strainVolume%xc(3,in%strainVolume%ns), &
                             in%strainVolume%width(in%strainVolume%ns), &
                             in%strainVolume%thickness(in%strainVolume%ns), &
                             in%strainVolume%dip(in%strainVolume%ns), &
                             in%strainVolume%sv(3,in%strainVolume%ns), &
                             in%strainVolume%dv(3,in%strainVolume%ns), &
                             in%strainVolume%nv(3,in%strainVolume%ns),STAT=ierr)
       IF (ierr>0) STOP "slave could not allocate memory for strain volumes"

       DO i=1,in%strainVolume%ns
          position=0
          CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%e22,        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%e23,        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%e33,        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%x(2,i),          1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%x(3,i),          1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%width(i),        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%thickness(i),    1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%dip(i),          1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%Gk,         1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%gammadot0k, 1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%dok,        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%mk,         1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%Qk,         1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%Rk,         1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%Gm,         1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%gammadot0m, 1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%dom,        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%mm,         1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%Qm,         1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%Rm,         1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%nGk,        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s0(i)%s22,       1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s0(i)%s23,       1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s0(i)%s33,       1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%ngammadot0k,1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%npowerk,    1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%nQk,        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%nRk,        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%ngammadot0m,1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%npowerm,    1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%nQm,        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%nRm,        1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%rhoc,       1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%strainVolume%s(i)%To,         1,MPI_REAL8,MPI_COMM_WORLD,ierr)
       END DO

       IF (0 .LT. in%nObservationState) &
                    ALLOCATE(in%observationState(in%nObservationState,2), &
                             STAT=ierr)
       IF (ierr>0) STOP "slave could not allocate memory for observation states"

       DO i=1,in%nObservationState
          position=0
          CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%observationState(i,1),1,MPI_INTEGER,MPI_COMM_WORLD,ierr)
       END DO

       IF (0 .LT. in%nObservationPoint) &
                    ALLOCATE(in%observationPoint(in%nObservationPoint), &
                             STAT=ierr)
       IF (ierr>0) STOP "slave could not allocate memory for observation points"

       DO i=1,in%nObservationPoint
          position=0
          CALL MPI_BCAST(packed,psize,MPI_PACKED,0,MPI_COMM_WORLD,ierr)
          CALL MPI_UNPACK(packed,psize,position,in%observationPoint(i)%name,10,MPI_CHARACTER,MPI_COMM_WORLD,ierr)
          DO k=1,3
             CALL MPI_UNPACK(packed,psize,position,in%observationPoint(i)%x(k),1,MPI_REAL8,MPI_COMM_WORLD,ierr)
          END DO
       END DO

    END IF ! master or slaves

    in%nPatch=in%patch%ns
    in%nVolume=in%strainVolume%ns

2000 FORMAT ("# ----------------------------------------------------------------------------")
     
  END SUBROUTINE init

  !-----------------------------------------------
  !> subroutine printhelp
  !! displays a help message with master thread.
  !-----------------------------------------------
  SUBROUTINE printhelp()
  
    INTEGER :: rank,size,ierr
    INCLUDE 'mpif.h'
    
    CALL MPI_COMM_RANK(MPI_COMM_WORLD,rank,ierr)
    CALL MPI_COMM_SIZE(MPI_COMM_WORLD,size,ierr)
    
    IF (0.EQ.rank) THEN
       PRINT '("usage:")'
       PRINT '("")'
       PRINT '("mpirun -n 2 unicycle-ps-viscouscycles [-h] [--dry-run] [--help] [--epsilon 1e-6] [filename]")'
       PRINT '("")'
       PRINT '("options:")'
       PRINT '("   -h                      prints this message and aborts calculation")'
       PRINT '("   --dry-run               abort calculation, only output geometry")'
       PRINT '("   --export-netcdf         export the kinematics to a netcdf file")'
       PRINT '("   --help                  prints this message and aborts calculation")'
       PRINT '("   --version               print version number and exit")'
       PRINT '("   --epsilon               set the numerical accuracy [1E-6]")'
       PRINT '("   --export-greens wdir    export the Greens function to file")'
       PRINT '("   --maximum-iterations    set the maximum time step [1000000]")'
       PRINT '("   --maximum-step          set the maximum time step [none]")'
       PRINT '("")'
       PRINT '("description:")'
       PRINT '("   simulates elasto-dynamics on faults in plane strain")'
       PRINT '("   in viscoelastic media with the radiation-damping approximation")'
       PRINT '("   using the integral method.")'
       PRINT '("")'
       PRINT '("   if filename is not provided, reads from standard input.")'
       PRINT '("")'
       PRINT '("see also: ""man unicycle""")'
       PRINT '("")'
       CALL FLUSH(6)
    END IF
    
  END SUBROUTINE printhelp
  
  !-----------------------------------------------
  !> subroutine printversion
  !! displays code version with master thread.
  !-----------------------------------------------
  SUBROUTINE printversion()
    
    INTEGER :: rank,size,ierr
    INCLUDE 'mpif.h'
    
    CALL MPI_COMM_RANK(MPI_COMM_WORLD,rank,ierr)
    CALL MPI_COMM_SIZE(MPI_COMM_WORLD,size,ierr)
    
    IF (0.EQ.rank) THEN
       PRINT '("unicycle-ps-viscouscycles version 1.0.0, compiled on ",a)', __DATE__
       PRINT '("")'
       CALL FLUSH(6)
    END IF
  
  END SUBROUTINE printversion
    
END PROGRAM viscouscycles

