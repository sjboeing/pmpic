!Reads in an existing parcel dump file for use in a simulation
!(restart from a checkpoint or from an initial condition constructed by an external script)
module readfromfile_parcelsetup_mod
  use state_mod, only : model_state_type
  use datadefn_mod, only: DEFAULT_PRECISION, PRECISION_TYPE, STRING_LENGTH,&
   LONG_INTEGER, DOUBLE_PRECISION, PARCEL_INTEGER, MPI_PARCEL_INT
  use optionsdatabase_mod, only: options_get_integer
  use parcel_interpolation_mod, only: x_coords, y_coords, z_coords
  use MPI
  use timer_mod
  use monc_component_mod, only: component_descriptor_type

implicit none

integer(kind=LONG_INTEGER) :: loc, realsize, parcelsize, metadatasize

contains

  type(component_descriptor_type) function readfromfile_parcelsetup_get_descriptor()
    readfromfile_parcelsetup_get_descriptor%name="readfromfile_parcelsetup"
    readfromfile_parcelsetup_get_descriptor%version=0.1
    readfromfile_parcelsetup_get_descriptor%initialisation=>initialisation_callback

  end function readfromfile_parcelsetup_get_descriptor

  subroutine initialisation_callback(state)
    type(model_state_type), intent(inout), target :: state
    integer :: file_number
    character (len=23) :: filename
    integer:: my_rank, rank
    logical :: exist
    integer :: numfiles
    integer :: ierr
    real(kind=DEFAULT_PRECISION), allocatable, dimension(:,:) :: ranges
    real (kind=DEFAULT_PRECISION) :: time
    integer(kind=PARCEL_INTEGER) :: nparcels, total, filetotal
    integer :: handle

    call register_routine_for_timing("read_parcels",handle,state)
    call timer_start(handle)

    file_number = options_get_integer(state%options_database,"restart_num")
    state%iterations=file_number

    my_rank = state%parallel%my_rank

    if (my_rank .eq. 0) print *, "restart from file number", file_number

    !we count the number of restart files
    if (my_rank .eq. 0) then
      rank = 0
      numfiles=0

      print *, "checking for restart files with file number", file_number

      do
        write(filename,"(A8,i5.5,A1,I5.5,A4)") "parcels_", rank,"_", file_number, ".dat"
        inquire(file=filename, exist=exist)
        if (.not. exist .and. rank .eq. 0) then
          print *, "there is no file to restart from"
          error stop
        else if (.not. exist) then
          exit
        endif
        numfiles=numfiles+1
        rank = rank+1
        print *, "file ",filename," exists!"
      enddo

      Print *, "Found ", numfiles, "files"
      print *, ""

    endif

    call MPI_Bcast(numfiles, 1, MPI_INTEGER, 0, state%parallel%monc_communicator,ierr)

    allocate(ranges(6,numfiles))

    total=0

    !we open each restart file and record each file's spatial range
    if (my_rank .eq. 0) then
      print *, "Reading position information from each file:"
      do rank=0,numfiles-1
        write(filename,"(A8,i5.5,A1,I5.5,A4)") "parcels_", rank,"_", file_number, ".dat"
        open(unit=10,file=filename,access="stream",form="unformatted")
        read(10) time
        read(10) ranges(:,rank+1)
        read(10) filetotal
        close(10)

        total=total+filetotal

        write(*,"(a,i3.3,a,f5.0,1x,f5.0,2x,f5.0,1x,f5.0,2x,f5.0,1x,f5.0)") &
         "File ",rank,": [xmin,xmax, ymin,ymax, zmin,zmax]=",ranges(:,rank+1)


      enddo
      print *, ""
      print *, "Now reading files in:"


    endif

    !broadcast this to all processes
    call MPI_Bcast(ranges, numfiles*6, PRECISION_TYPE, 0, state%parallel%monc_communicator,ierr)

    !now we wanna open each file (if it is within our rank's spatial range) and read parcels from it
    nparcels=0

    do rank=0,numfiles-1

      if (check_ranges(state,ranges(:,rank+1))) then
        write(filename,"(A8,i5.5,A1,I5.5,A4)") "parcels_", rank,"_", file_number, ".dat"
        call read_file(state,filename,nparcels)
      endif
    enddo

    state%parcels%numparcels_local=nparcels

    !set global parcel count
    call MPI_Allreduce(state%parcels%numparcels_local,&
                       state%parcels%numparcels_global,&
                       1,&
                       MPI_PARCEL_INT,&
                       MPI_SUM,&
                       state%parallel%monc_communicator,&
                       ierr)

    call MPI_Barrier(state%parallel%monc_communicator,ierr)

    if (my_rank .eq. 0) then
       !sanity check that we read in all the parcels
       if (total .eq. state%parcels%numparcels_global) then
         print *, "All files read in successfully"
         print *, "Total parcel count read in = ", state%parcels%numparcels_global
       else
         print *, "Error - incorrect parcel count read in"
         error stop
       endif
    endif

    call timer_stop(handle)

    !call MPI_Barrier(state%parallel%monc_communicator,ierr)
    !print *, my_rank, state%parcels%numparcels_local
    !call MPI_Finalize(ierr)
    !stop

  end subroutine

!check if file's range is within the rank's range
  logical function check_ranges(state,ranges)
    type(model_state_type),intent(in) :: state
    real(kind=DEFAULT_PRECISION), intent(in) :: ranges(*)
    real (kind=DEFAULT_PRECISION) :: xmin, xmax, ymin, ymax, zmin, zmax

    xmin=x_coords(state%local_grid%local_domain_start_index(3))
    xmax=x_coords(state%local_grid%local_domain_end_index(3)+1)

    ymin=y_coords(state%local_grid%local_domain_start_index(2))
    ymax=y_coords(state%local_grid%local_domain_end_index(2)+1)

    zmin=z_coords(state%local_grid%local_domain_start_index(1))
    zmax=z_coords(state%local_grid%local_domain_end_index(1))

    if (ranges(1) .lt. xmax) then
      if (ranges(2) .gt. xmin) then
        if (ranges(3) .lt. ymax) then
          if (ranges(4) .gt. ymin) then
            check_ranges = .true.
            return
          endif
        endif
      endif
    endif
    check_ranges = .false.
    return

  end function

!read in a file and add its parcels (where approproate) to the current state
  subroutine read_file(state,filename,nparcels)
    type(model_state_type), intent(inout) :: state
    character(len=20), intent(in) :: filename
    integer(kind=PARCEL_INTEGER), intent(inout) :: nparcels
    integer(kind=PARCEL_INTEGER) :: n, ninfile

    real(kind=DEFAULT_PRECISION), allocatable :: x(:), y(:), z(:)
    real(kind=DEFAULT_PRECISION) :: xmin, xmax, ymin, ymax

    xmin=x_coords(state%local_grid%local_domain_start_index(3))
    xmax=x_coords(state%local_grid%local_domain_end_index(3)+1)

    ymin=y_coords(state%local_grid%local_domain_start_index(2))
    ymax=y_coords(state%local_grid%local_domain_end_index(2)+1)

    !get the size of a real
    if (DEFAULT_PRECISION .eq. DOUBLE_PRECISION) then
      realsize=8
    else
      realsize=4
    endif

    !get the size of a parcel integer
    if (PARCEL_INTEGER .eq. LONG_INTEGER) then
      parcelsize=8
    else
      parcelsize=4
    endif

    !print *, "datasize=",realsize
    !print *, "parcelsize=", parcelsize

    print *, "rank ",state%parallel%my_rank, " opening file ", filename

    open(unit=10,file=filename,access="stream",form="unformatted")
    inquire(unit=10,pos=loc)
      !print *, "loc=",loc
    read(10) state%time
    inquire(unit=10,pos=loc)
    !print *, "loc=",loc
    read(10, pos=loc+6*realsize)
    inquire(unit=10,pos=loc)
    !print *, "loc=", loc
    read(10) ninfile
    !print *, "ninfile=", ninfile

    metadatasize=realsize+6*realsize+parcelsize

    !read in x, y and z positions of parcels in file
    !we don't want to read all properties so as to not waste memory
    allocate(x(ninfile),y(ninfile),z(ninfile))
    read(10) x, y, z

    !print *, "nparcels initial=", nparcels

    !we now want to step through the parcels and see which are in our domain. If they are, read them in
    do n=1,ninfile
      if (x(n) .lt. xmax .and. x(n) .ge. xmin) then
        if (y(n) .lt. ymax .and. y(n) .ge. ymin) then
          call read_parcel(state, n, nparcels, ninfile)
          cycle
        endif
      endif
      !print *, n, xmin, x(n), xmax, ymin, y(n), ymax
    enddo

    deallocate(x,y,z)
    close(10)

  end subroutine



  !reads the "n"th parcel from the file into the current state
  subroutine read_parcel(state,n,nparcels, ninfile)
    type(model_state_type), intent(inout) :: state
    integer(kind=PARCEL_INTEGER), intent(in) :: n, ninfile
    integer(kind=PARCEL_INTEGER), intent(inout) :: nparcels
    integer(kind=LONG_INTEGER) :: loc

    !position of x coordinate of nth parcel in file
    loc = metadatasize+ ((n-1)*realsize) + 1

    nparcels=nparcels+1

    read(10, pos=loc) state%parcels%x(nparcels)
    loc=loc + (ninfile*realsize) !move location onto next property for that parcel
    read(10, pos=loc) state%parcels%y(nparcels)
    loc=loc + (ninfile*realsize)
    read(10, pos=loc) state%parcels%z(nparcels)
    loc=loc + (ninfile*realsize)

    read(10, pos=loc) state%parcels%p(nparcels)
    loc=loc + (ninfile*realsize)
    read(10, pos=loc) state%parcels%q(nparcels)
    loc=loc + (ninfile*realsize)
    read(10, pos=loc) state%parcels%r(nparcels)
    loc=loc + (ninfile*realsize)

    read(10, pos=loc) state%parcels%dxdt(nparcels)
    loc=loc + (ninfile*realsize)
    read(10, pos=loc) state%parcels%dydt(nparcels)
    loc=loc + (ninfile*realsize)
    read(10, pos=loc) state%parcels%dzdt(nparcels)
    loc=loc + (ninfile*realsize)

    read(10, pos=loc) state%parcels%dpdt(nparcels)
    loc=loc + (ninfile*realsize)
    read(10, pos=loc) state%parcels%dqdt(nparcels)
    loc=loc + (ninfile*realsize)
    read(10, pos=loc) state%parcels%drdt(nparcels)
    loc=loc + (ninfile*realsize)

    read(10, pos=loc) state%parcels%h(nparcels)
    loc=loc + (ninfile*realsize)
    read(10, pos=loc) state%parcels%b(nparcels)
    loc=loc + (ninfile*realsize)
    read(10, pos=loc) state%parcels%vol(nparcels)
    loc=loc + (ninfile*realsize)

    read(10, pos=loc) state%parcels%stretch(nparcels)
    loc=loc + (ninfile*realsize)
    read(10, pos=loc) state%parcels%tag(nparcels)


    !qvalues are a bit different as their stride isn't realsize but qnum*realsize
    loc = metadatasize + ninfile*realsize*state%parcels%n_properties &
          + (n-1)*realsize*state%parcels%qnum + 1


    read(10,pos=loc) state%parcels%qvalues(:,nparcels)


  end subroutine




end module
